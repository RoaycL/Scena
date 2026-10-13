<p align="center">
  <img src="wallhaven/Assets.xcassets/AppIcon.appiconset/mac512@2x.png" width="112" alt="Scena 应用图标">
</p>

# Scena

让壁纸成为桌面上的风景。

Scena 是一款 macOS 壁纸应用，集高清图片、动态壁纸、Steam 创意工坊和播放列表于一体。浏览喜欢的内容，导入自己的素材，或让壁纸按设定的节奏自动切换。

[下载最新版](https://github.com/RoaycL/Scena/releases/latest) · [更新记录](CHANGELOG.md) · [反馈问题](https://github.com/RoaycL/Scena/issues)

## 功能

| 功能 | 说明 |
| --- | --- |
| 壁纸发现 | 浏览和搜索 [wallhaven](https://wallhaven.cc) 高清图片、Wallpaper Engine 创意工坊壁纸 |
| 工坊筛选 | 类型、年龄分级、标签、分辨率、排序，以及广受好评、显示或隐藏动漫等筛选 |
| 收藏与订阅 | 同步 wallhaven 收藏；通过 Steam 账号查看、添加和取消工坊订阅 |
| 本地素材 | 管理下载的壁纸，导入自己的图片和视频，直接预览动态内容 |
| 动态桌面 | 播放视频、工坊场景和网页壁纸，支持多显示器、音量及屏幕开关 |
| 播放列表 | 大图预览与横向缩略图队列，支持命名、多选、拖动排序及暂停播放，按间隔顺序或随机轮换 |
| 下载管理 | 单项或批量暂停、停止、恢复和重试；保存未完成任务，重启后手动继续 |
| 桌面控制 | 菜单栏控制、全局快捷键、开机启动、Dock 图标开关与自动暂停 |
| 存储与更新 | 支持外接盘保存素材，通过 GitHub Releases 检查和下载应用更新 |

## 下载与安装

- **系统：macOS 14.0 或更高版本。**
- **架构：Apple 芯片和 Intel Mac，使用同一个安装包。**

1. 前往 [最新发布页](https://github.com/RoaycL/Scena/releases/latest)，下载 `Scena-版本号.zip`。
2. 解压，将 `Scena.app` 拖入「应用程序」目录后打开。
3. 如需校验下载文件，可使用同一发布页中的 `SHA256SUMS.txt`。

当前安装包使用 Apple Development 签名，尚未经过 Apple 公证。首次打开可能受到系统安全检查限制，可在「系统设置 → 隐私与安全性」查看提示；请确认安装包来自本仓库的发布页。

macOS 14 的适配已通过双架构编译和最低版本检查，尚未完成 macOS 14 实机验证。

从正式安装的 Scena 打开「设置 → 关于 → 更新」，可在应用内下载新版并重启安装，下载过程中会显示进度及文件大小，也可取消下载。开启「自动下载更新」后，发现新版会在后台下载；完成后选择「立即重启」，或选择「稍后」在退出时安装。从 Xcode 构建目录运行的开发版本会打开 GitHub 发布页，避免覆盖开发产物。

## 开始使用

### 图片与本地视频

在「发现」中浏览图片，下载后可在本地素材中管理。菜单栏提供素材导入入口；缩略图右键菜单可将素材加入播放列表。

发现页会记住上次的搜索词与筛选条件。大图预览每 5 秒切换，末尾循环；搜索、筛选和菜单操作期间暂停切换。手动选择缩略图后暂停自动切换，连续 1 分钟无操作后恢复轮播。预览切换不会自动将图片设置为桌面壁纸。

播放列表以大图展示选中的壁纸，下方横向队列可单击预览、双击播放、拖动排序，按住 Command 多选后可批量移除。顶部菜单支持切换、新建和重命名列表，大图下方可暂停或继续播放、调整轮换间隔与随机播放。

使用 wallhaven 线上收藏功能时，在设置中填写自己的 wallhaven API Key。

### Wallpaper Engine 创意工坊

浏览公开工坊内容不需要先登录。订阅同步与壁纸下载使用两套独立的 Steam 登录状态：

1. **同步订阅：** 在应用中打开 Steam 官方登录页。登录后可以同步订阅、订阅或取消订阅壁纸。Scena 使用登录后的会话，不读取或保存页面中输入的密码。
2. **下载壁纸：** 安装 [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD)，在设置中填写 Steam 账号名，点击「在终端登录」，按提示输入密码及 Steam Guard 验证码。账号需要已购买 Wallpaper Engine。

使用 Homebrew 安装 SteamCMD：

```bash
brew install --cask steamcmd
```

SteamCMD 会管理自己的登录缓存。Steam 网页登录成功不代表 SteamCMD 已登录，可以在设置中查看和检查下载登录状态。

Scena 与 Windows 上的 Wallpaper Engine 使用同一个 Steam 账号的订阅列表。在 Scena 中订阅或取消订阅会更新 Steam 账号；启用自动下载订阅后，同步会先扫描本地素材，再将缺失的可播放壁纸加入下载队列。壁纸文件仍需在每台设备上分别下载。

### 下载暂停与恢复

在「下载任务」中控制单项或整组任务。暂停会终止当前下载进程并保留部分文件，恢复后由 SteamCMD 校验和复用；停止一项任务时，同批其他未完成条目会重新排队。

每批最多 10 项，共用一次 SteamCMD 登录，批次串行执行。重启应用后，未完成任务可以手动恢复。实际续传效果取决于 SteamCMD 对部分文件的校验结果。

### 存储位置

在设置中选择素材保存位置，可以使用外接盘。素材按来源整理为：

```text
Scena/
├── Wallhaven/
├── Wallpaper Engine/
└── Imported/
```

从旧版升级会保留原有设置与素材库。

## 工坊兼容性

Scena 使用 [webwallgl](https://github.com/oneincase/webwallgl) 在 WebKit 中渲染工坊内容。支持视频、场景和网页类型，但复杂场景、特定效果或依赖 Windows 功能的壁纸可能无法完整呈现；Windows「应用」类型壁纸不支持播放。

发现无法播放的壁纸时，请在 [Issues](https://github.com/RoaycL/Scena/issues) 提供工坊链接、macOS 版本和问题表现，便于定位。

## 从源码构建

使用 Xcode 打开 `wallhaven.xcodeproj`，选择 `wallhaven` scheme。产品名称为 `Scena.app`；工程和 scheme 名称仍保留 `wallhaven`。Kingfisher 依赖由 Swift Package Manager 自动获取。

当前发布构建使用 Xcode 27.0。开发工具版本与应用最低系统版本独立，应用目标为 macOS 14.0。

```bash
# 开发构建
xcodebuild -project wallhaven.xcodeproj -scheme wallhaven -configuration Debug build

# 双架构 Release 构建
xcodebuild -project wallhaven.xcodeproj -scheme wallhaven \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build

# 单元测试
xcodebuild test -project wallhaven.xcodeproj -scheme wallhaven \
  -destination 'platform=macOS' -only-testing:wallhavenTests
```

本地构建时需要配置自己的签名团队。

## 发布维护

1. 更新工程的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，在 [CHANGELOG.md](CHANGELOG.md) 添加版本说明。
2. 构建并校验 Release 安装包，提交代码和对应的 `v版本号` 标签。
3. 上传包含顶层 `Scena.app` 的 ZIP 到 GitHub Release，并附上更新说明和校验文件。

`scripts/release.sh` 提供构建、打包和创建 Release 的辅助流程，支持 `--draft`。正式发布时请核对架构和签名，并验证线上下载文件。应用的更新功能读取本仓库的最新正式 Release。

## 致谢

- [webwallgl](https://github.com/oneincase/webwallgl)（MIT）：Wallpaper Engine 壁纸渲染。
- [Kingfisher](https://github.com/onevcat/Kingfisher)（MIT）：图片加载与缓存。
- [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)、[RePKG](https://github.com/notscuffed/repkg)：目录与格式约定参考。

Scena 与 Steam、Wallpaper Engine、wallhaven 均无官方关联。壁纸内容的版权归各自作者所有，请遵守作者及平台的使用要求。
