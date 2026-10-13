# Scena

macOS 沉浸式壁纸应用：浏览 [wallhaven](https://wallhaven.cc) 高清壁纸，播放 Wallpaper Engine 创意工坊的场景 / 网页 / 视频动态壁纸，管理本地图片和视频，用播放列表自动轮换。

## 功能

- **发现**：沉浸式浏览 wallhaven 壁纸；网格浏览 Wallpaper Engine 创意工坊，支持官方分类、分级、分辨率等筛选和搜索
- **收藏**：wallhaven 收藏夹（可同步线上收藏）；Steam 创意工坊订阅（与 Windows 上的 Wallpaper Engine 双向同步）
- **资料库**：wallhaven 下载、导入的图片和视频、已下载的工坊壁纸，按来源筛选
- **动态壁纸**：视频与工坊壁纸在所有显示器的桌面层播放，锁屏 / 睡眠时自动暂停，退出时定格为静态壁纸
- **播放列表**：多个列表，按间隔顺序或随机自动切换
- **存储**：可设到外接盘，统一存放在 `Scena/{Wallhaven, Wallpaper Engine, Imported}`
- 原生菜单栏、状态栏图标、键盘快捷键、通过 GitHub Releases 自动检查更新

## 运行环境

- macOS 26.4 及以上
- 下载创意工坊壁纸需要 [steamcmd](https://developer.valvesoftware.com/wiki/SteamCMD)（`brew install --cask steamcmd`）和**已购买 Wallpaper Engine 的 Steam 账号**。首次在终端里登录 steamcmd，Scena 不会读取或保存密码。

## 构建

用 Xcode 打开 `wallhaven.xcodeproj`，选择 `wallhaven` scheme 运行。依赖（Kingfisher）通过 Swift Package Manager 自动获取。

```bash
xcodebuild -project wallhaven.xcodeproj -scheme wallhaven -configuration Debug build
xcodebuild test -project wallhaven.xcodeproj -scheme wallhaven -only-testing:wallhavenTests
```

## 发布新版本

App 内的「检查更新」读取本仓库的 [GitHub Releases](https://github.com/RoaycL/Scena/releases)：tag 形如 `v1.0.3`，附带包含 `Scena.app` 的 `.zip`。

1. 在工程里提高 `MARKETING_VERSION`，并在 `CHANGELOG.md` 写好对应版本的说明
2. 运行 `scripts/release.sh`（加 `--draft` 先创建草稿），脚本会构建 Release、打包 zip 并创建 GitHub Release

## 致谢

- [webwallgl](https://github.com/oneincase/webwallgl)（MIT）：Wallpaper Engine 壁纸渲染
- [Kingfisher](https://github.com/onevcat/Kingfisher)（MIT）：图片加载与缓存
- 参考了 [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)、[RePKG](https://github.com/notscuffed/repkg) 等项目的目录与格式约定

创意工坊内容的版权归各自作者所有，请仅用于个人用途。
