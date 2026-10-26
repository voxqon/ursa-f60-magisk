"use strict";

const $ = (id) => document.getElementById(id);
const script = "/data/adb/modules/ursa_ndt_f60/manage.sh";
let state = null;
let working = false;
let selectedAction = null;
let callbackId = 0;

function execute(action) {
  if (!["status", "log", "install", "uninstall"].includes(action)) {
    return Promise.reject(new Error("无效操作。"));
  }
  if (!window.ksu || typeof window.ksu.exec !== "function") {
    return Promise.reject(new Error("未连接到 Root 管理器，无法读取设备状态。"));
  }
  return new Promise((resolve, reject) => {
    const callback = `f60Callback${++callbackId}`;
    const mutation = action === "install" || action === "uninstall";
    let timer;
    const cleanup = () => {
      clearTimeout(timer);
      delete window[callback];
    };
    window[callback] = (code, stdout, stderr) => {
      cleanup();
      resolve({ code: Number(code), stdout: String(stdout || ""), stderr: String(stderr || "") });
    };
    // Never time out a partition operation while it may still be running.
    if (!mutation) {
      timer = setTimeout(() => {
        cleanup();
        reject(new Error("读取超时，设备可能仍在执行操作，请稍后刷新。"));
      }, 30000);
    }
    try {
      window.ksu.exec(`sh ${script} ${action}${mutation ? " --confirm" : ""}`, "{}", callback);
    } catch (error) {
      cleanup();
      reject(error);
    }
  });
}

function decodeFields(output) {
  const result = {};
  for (const line of output.trim().split("\n")) {
    const separator = line.indexOf("\t");
    if (separator < 0) continue;
    const key = line.slice(0, separator);
    if (!/^[a-z_]+$/.test(key)) continue;
    const bytes = Uint8Array.from(atob(line.slice(separator + 1)), (value) => value.charCodeAt(0));
    result[key] = new TextDecoder().decode(bytes);
  }
  if (result.protocol !== "1" ||
      !["supported", "ready", "busy", "running", "driver"].every((key) => ["0", "1"].includes(result[key])) ||
      !["unknown", "fixed", "restored", "changed"].includes(result.disk)) {
    throw new Error("设备返回的状态不完整，请刷新重试。");
  }
  return result;
}

function notice(message, error = false) {
  $("notice").textContent = message;
  $("notice").hidden = !message;
  $("notice").dataset.error = String(error);
}

function buttons() {
  const available = !working && state?.supported === "1" && state?.ready === "1" && state?.busy === "0";
  $("refresh").disabled = working;
  $("install").disabled = !available || state?.disk === "changed" || state?.disk === "fixed";
  $("uninstall").disabled = !available || state?.disk !== "fixed" || !state?.backup;
}

function render() {
  let title = "等待安装";
  let description = "尚未找到本模块的修复安装记录。";
  let tone = "neutral";
  if (state.supported !== "1") {
    title = "系统不匹配"; description = "当前系统没有对应的修复内核，已禁用安装和卸载。"; tone = "error";
  } else if (state.ready !== "1") {
    title = "当前环境不可操作"; description = "Root 版本、boot 布局或模块启用状态不满足要求。"; tone = "error";
  } else if (state.busy === "1") {
    title = "操作进行中"; description = "正在处理 boot，完成后请刷新状态。"; tone = "warning";
  } else if (state.disk === "changed") {
    title = "Boot 已发生变化"; description = "当前 boot 与安装记录不一致，已禁用写入。"; tone = "error";
  } else if (state.disk === "fixed") {
    if (state.running !== "1") {
      title = "已安装，等待重启"; description = "先将安装前备份导出到电脑，再手动重启。"; tone = "warning";
    } else if (state.driver !== "1") {
      title = "修复内核已运行"; description = "未检测到 F60 压力驱动绑定，请检查设备日志。"; tone = "warning";
    } else {
      title = "修复已生效"; description = "已检测到 F60 内核和压力驱动，请实测指纹录入及解锁。"; tone = "success";
    }
  } else if (state.disk === "restored") {
    if (state.running === "1") {
      title = "已卸载，等待重启"; description = "安装前 boot 已恢复，重启后完成修复卸载。"; tone = "warning";
    } else {
      title = "修复已卸载"; description = "安装前 boot 已恢复，备份与管理页面保留。";
    }
  } else if (state.running === "1" && state.driver === "1") {
    title = "压力驱动正在运行"; description = "没有匹配的安装备份，无法从此页面卸载修复。"; tone = "warning";
  }
  $("status-title").textContent = title;
  $("status-description").textContent = description;
  $("status-band").dataset.tone = tone;
  $("status-band").setAttribute("aria-busy", state.busy === "1" ? "true" : "false");
  $("disk-status").textContent = { fixed: "已安装", restored: "已恢复", changed: "与记录不一致", unknown: "未记录" }[state.disk];
  $("driver-status").textContent = state.driver === "1" ? "已绑定" : "未检测到";
  for (const id of ["rom", "root", "kernel", "version"]) $(id).textContent = state[id] || "—";
  $("backup").textContent = state.backup || "暂无匹配的安装前备份";
  buttons();
}

function disconnected(error) {
  state = null;
  $("status-title").textContent = "无法读取状态";
  $("status-description").textContent = error.message;
  $("status-band").dataset.tone = "error";
  $("status-band").setAttribute("aria-busy", "false");
  $("disk-status").textContent = "未知";
  $("driver-status").textContent = "未知";
  for (const id of ["rom", "root", "kernel", "version", "backup"]) $(id).textContent = "—";
  buttons();
}

async function refresh() {
  if (working) return;
  working = true;
  buttons();
  try {
    const result = await execute("status");
    if (result.code !== 0) throw new Error(result.stderr || result.stdout || "读取失败。");
    state = decodeFields(result.stdout);
    const logs = await execute("log");
    if (logs.code === 0) $("log").textContent = logs.stdout || "暂无操作记录。";
    render();
  } catch (error) {
    disconnected(error);
  } finally {
    working = false;
    buttons();
  }
}

function confirmAction(action) {
  if (working || $(action).disabled) return;
  selectedAction = action;
  const install = action === "install";
  $("confirm-title").textContent = install ? "安装 F60 修复？" : "卸载 F60 修复？";
  $("confirm-description").textContent = install
    ? "将备份当前 boot 并写入匹配的修复内核。完成后请导出备份，再手动重启。"
    : "将校验并恢复本次安装前的 boot，保留管理页面和备份。完成后需要手动重启。";
  $("confirm").textContent = install ? "确认安装" : "确认卸载";
  $("confirm").className = install ? "primary" : "danger";
  $("confirm-dialog").showModal();
  $("cancel").focus();
}

async function runOperation() {
  const action = selectedAction;
  selectedAction = null;
  $("confirm-dialog").close();
  if (!action || working || $(action).disabled) return;
  working = true;
  buttons();
  $("status-band").setAttribute("aria-busy", "true");
  $("status-title").textContent = action === "install" ? "正在安装修复" : "正在恢复安装前备份";
  $("status-description").textContent = "请保持页面打开，等待写入和回读校验完成。";
  notice("");
  $("log").textContent = "操作正在执行…";
  try {
    const result = await execute(action);
    $("log").textContent = [result.stdout, result.stderr].filter(Boolean).join("\n") || "操作未返回日志。";
    if (result.code !== 0) {
      notice("操作未完成。请检查下方日志；出现 RECOVERY-REQUIRED 时请先恢复备份，不要重启。", true);
    } else {
      notice(action === "install"
        ? "安装操作完成。请导出安装前备份，确认后手动重启。"
        : "卸载操作完成。请手动重启，管理页面与备份继续保留。");
    }
  } catch (error) {
    notice(`${error.message} 请刷新确认设备状态。`, true);
  } finally {
    working = false;
    await refresh();
  }
}

$("refresh").addEventListener("click", refresh);
$("install").addEventListener("click", () => confirmAction("install"));
$("uninstall").addEventListener("click", () => confirmAction("uninstall"));
$("cancel").addEventListener("click", () => { selectedAction = null; $("confirm-dialog").close(); });
$("confirm").addEventListener("click", runOperation);
$("confirm-dialog").addEventListener("cancel", () => { selectedAction = null; });
refresh();
