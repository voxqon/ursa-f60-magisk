# Ursa F60 Fix

小米 8 探索版屏下指纹压力驱动修复模块。启用内核 `CONFIG_INPUT_PRESS_NDT_F60`，
提供管理页面查看状态、安装修复及恢复原内核，不修改指纹库阈值。

## 兼容范围

| 项目 | 要求 |
| --- | --- |
| 设备 | 小米 8 探索版 `ursa` |
| 系统 | `22.2-20261020-NIGHTLY-ursa`，增量号 `8450b6a354`，SDK 35 |
| Root | Magisk 30.2，或 APatch 11282 / KernelPatch 0.13.9 |
| 环境 | Bootloader 已解锁，boot 已有对应 root 补丁，`/data` 可用空间至少 1 GiB |

仅适用于上述构建。**实验版本，管理页面的安装和卸载修复会写入 boot；实机安装后重启及长期使用仍待验证。**

## 使用

1. 在 Magisk 或 APatch 管理器中安装 `ursa-f60-magisk.zip`，无需解压。
2. 模块启用后打开管理页面。APatch 可直接打开；Magisk 需安装 [KsuWebUI](https://github.com/KOWX712/KsuWebUIStandalone)，再点击模块“操作”。
3. 点击“安装修复”并确认。完成后，将页面所示备份目录中的 `boot-before.img` 导出到电脑，并核对同目录 `SHA256SUMS`。
4. 手动重启，先输入锁屏密码，再验证指纹录入和解锁。

安装 ZIP 仅添加管理模块。页面分别显示 boot 修复与当前驱动状态，写入后需重启才切换运行内核。
备份和日志位于 `/data/adb/ursa_ndt_f60/`。

点击“卸载修复”会校验并恢复安装前 boot，保留管理页面和备份，完成后手动重启。
**直接禁用或删除模块不会恢复原内核。** 仅恢复相同系统版本的备份。

页面不可用时，可在 root 终端恢复：

```sh
sh /data/adb/modules/ursa_ndt_f60/restore.sh --restore /data/adb/ursa_ndt_f60/backup-实际目录
```

无法启动时，用电脑执行 `fastboot flash boot boot-before.img`，确认成功后再执行 `fastboot reboot`。

## 打包

需要 Python 3.12+。Windows 还需启动 Docker Desktop 的 Linux 容器模式；
Linux x86_64 可直接执行工具。

将匹配的修复内核放到 `inputs/lineage-22.2-20261020-ursa/Image.gz-dtb`，在仓库根目录执行：

```sh
python -B tools/build.py --fetch
```

脚本下载并校验固定输入，输出 `dist/ursa-f60-magisk.zip` 及 SHA-256 校验文件。
内核需自行编译；版本和输入固定在 `targets/`、`config/`、`configs/`。
输入镜像、工具缓存和构建产物不纳入 Git。

## 许可

项目自身代码采用 [MIT License](LICENSE)。第三方代码、工具、内核和图标保留各自许可，
见 `third_party/avb/LICENSE`、`module/webroot/LICENSE.icons`。
Magisk 工具来自[官方 30.2](https://github.com/topjohnwu/Magisk/tree/v30.2)，
KernelPatch 工具来自[官方 0.13.9](https://github.com/bmax121/KernelPatch/tree/b51197aaba8f2272dd8a3e30c85698a29aa928c9)（GPL-2.0-or-later），
内核来自 [LineageOS sdm845](https://github.com/LineageOS/android_kernel_xiaomi_sdm845)，具体提交见 target。
发布内核或 KernelPatch 二进制时，应同时提供对应完整源码、配置和构建说明。
