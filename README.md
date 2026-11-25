# Ursa F60 Fix

小米 8 探索版屏下指纹压力驱动修复模块。启用内核 `CONFIG_INPUT_PRESS_NDT_F60`，
提供管理页面查看状态、安装修复及恢复原内核，不修改指纹库阈值。

## 兼容范围

| 项目 | 要求 |
| --- | --- |
| 设备 | 小米 8 探索版 `ursa` |
| 已收录构建 | LineageOS 22.2 官方 `ursa` Nightly：2026-10-20、11-10、11-17、11-24 |
| 其他构建（包括未来 OTA） | Android 15（SDK 35），且 boot 通过内核家族、设备树、ramdisk 和 AVB 校验 |
| Root | Magisk 30.2，或 APatch 11282 / KernelPatch 0.13.9 |
| 环境 | Bootloader 已解锁，boot 已有对应 root 补丁，`/data` 可用空间至少 1 GiB |

未收录的构建也可以尝试安装，无需等模块更新版本列表。模块会检查实际 boot：只有内核仍属于已验证的 `aa8adfe9bf21` 系列，且其他启动组件通过校验，才会写入修复。较早的 Android 版本、新的 Android SDK、或更换了内核或启动布局的构建，需要单独验证并添加支持。管理页面的安装和卸载修复会写入 boot，请保留备份。

## 使用

1. 从 [Releases](https://github.com/voxqon/ursa-f60-magisk/releases/latest) 下载模块 ZIP，在 Magisk 或 APatch 管理器中安装，无需解压。
2. 模块启用后打开管理页面。APatch 可直接打开；Magisk 需安装 [KsuWebUI](https://github.com/KOWX712/KsuWebUIStandalone)，再点击模块“操作”。
3. 点击“安装修复”并确认。完成后，将页面所示备份目录中的 `boot-before.img` 导出到电脑，并核对同目录 `SHA256SUMS`。
4. 手动重启，先输入锁屏密码，再验证指纹录入和解锁。

安装 ZIP 仅添加管理模块。页面分别显示 boot 修复与当前驱动状态，写入后需重启才切换运行内核。
备份和日志位于 `/data/adb/ursa_ndt_f60/`。

### APatch 系统更新后恢复指纹

如果已经更新且 APatch Root 仍在，在 APatch 的模块页面安装新版 ZIP，重启使模块生效，再打开 WebUI，点击“安装修复”。看到“已安装，等待重启”后，导出备份并手动重启。

也可以提前在 WebUI 点“开启 OTA 后自动恢复”（默认关闭）。下载系统更新，在 APatch 选择“直接安装”，然后回到系统更新页面重启。更新后首次进入 Android，如果 APatch 仍有 Root，模块会检查更新后的 boot。校验通过后，它会备份当前 boot 并重新写入 F60 修复。打开 WebUI 查看结果；显示“已安装，等待重启”后，再手动重启一次加载修复内核。自动恢复不会代替 APatch 保留 Root，也不会自行重启。

如果新构建的 boot 校验不通过，或 APatch 版本不兼容，模块会停止且不写入。可在 WebUI 查看自动恢复日志。如果新内核已经绑定 F60 驱动，自动恢复会跳过。

点击“卸载修复”会关闭自动恢复、校验并恢复安装前 boot，保留管理页面和备份，完成后手动重启。
**直接禁用或删除模块不会恢复原内核。** 仅恢复相同系统版本的备份。

页面不可用时，可在 root 终端恢复：

```sh
sh /data/adb/modules/ursa_ndt_f60/restore.sh --restore /data/adb/ursa_ndt_f60/backup-实际目录
```

无法启动时，用电脑执行 `fastboot flash boot boot-before.img`，确认成功后再执行 `fastboot reboot`。

## 打包

需要 Python 3.12+。在仓库根目录执行：

```sh
python -B tools/build.py --fetch
```

脚本下载并校验固定输入，输出 `dist/ursa-f60-magisk.zip` 及 SHA-256 校验文件。当前构建可以复用校验固定的 v2.2.0 修复内核：新版 ROM 使用相同的内核源码提交、配置和设备树集合，各自保留原 boot 的设备树顺序、ramdisk 和构建校验。
添加新目标时，在 `targets/` 固定输入并按需提供编译好的 `Image.gz-dtb`。完整构建会对标记了 `adaptive_family` 的样本交叉校验，只允许明确识别的构建字段变化。计算未预先固定的 canonical ramdisk 哈希需要 Linux x86_64，或 Windows 上的 Docker Desktop Linux 容器模式。用 `--target` 可只打包指定目标，此时仅启用精确匹配。
输入镜像、工具缓存和构建产物不纳入 Git。

### 自动发布

将代码（包括新增的目标和配置文件）提交并推送到 GitHub 后，创建并推送与 `module/module.prop` 中 `version` 一致的标签，例如版本为 `2.3.0` 时：

```sh
git tag v2.3.0
git push origin v2.3.0
```

GitHub Actions 会下载并校验构建输入，打包模块，并自动创建附带 ZIP、SHA-256 校验文件和兼容性清单的 Release。只推送分支不会发布；发布标签必须采用 `v主版本.次版本.修订版本` 格式。工作流需要仓库启用 GitHub Actions，并允许 `GITHUB_TOKEN` 写入仓库内容；构建依赖的固定下载地址也必须可用。

## 许可

项目自身代码采用 [MIT License](LICENSE)。第三方代码、工具、内核和图标保留各自许可，
见 `third_party/avb/LICENSE`、`module/webroot/LICENSE.icons`。
Magisk 工具来自[官方 30.2](https://github.com/topjohnwu/Magisk/tree/v30.2)，
KernelPatch 工具来自[官方 0.13.9](https://github.com/bmax121/KernelPatch/tree/b51197aaba8f2272dd8a3e30c85698a29aa928c9)（GPL-2.0-or-later），
内核来自 [LineageOS sdm845](https://github.com/LineageOS/android_kernel_xiaomi_sdm845)，具体提交见 target。
发布内核或 KernelPatch 二进制时，应同时提供对应完整源码、配置和构建说明。
