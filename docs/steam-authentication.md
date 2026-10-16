# Steam 认证组件

状态：源码开发版，尚未发布。核验日期：2026-10-16。

## 用户行为

「设置 → 账户 → 登录 Steam」默认展示二维码。使用 Steam 手机 App 扫码并确认设备 `Scena for macOS` 后，应用同步订阅。关闭登录窗口会取消尚未完成的授权；成功后的窗口关闭不会取消随后的同步。

持久凭据保存在 macOS 登录钥匙串。重新启动时静默恢复，短期社区会话过期前按需刷新；明确撤销或失效才要求重新授权。断网和服务器故障保留持久凭据，允许重试。仍可明确选择网页登录，其会话有效期由 Steam 决定。

扫码登录后，创意工坊下载也使用此账号，直接从 Steam 内容 CDN 获取，不需要 steamcmd（账号需拥有 Wallpaper Engine，否则拿不到 depot 密钥）。网页登录或未登录时退回 SteamCMD，沿用其独立登录缓存。

## CDN 下载

- helper 方法 `download`：用钥匙串中的 refresh token 登录（LoginID 为订阅会话的 +1，两者可同时在线），不续签令牌。`PublishedFile.GetDetails` 取 `hcontent_file`，再取 manifest 请求码、depot 431960 的解密密钥和可用 CDN 服务器。
- 分片按服务器轮询并发下载（默认 8 路，失败换服务器重试），由 SteamKit 解密、解压并做 Adler32 校验，按偏移写入 `steamapps/workshop/downloads/scena/<id>`。完成后整体替换 `content/431960/<id>`，旧目录在移动成功后才删除。
- 暂停保留暂存文件，恢复时校验已有分片只补缺失部分；已安装目录中 SHA1 一致的文件直接复用。停止下载删除暂存。
- 清单中的文件名视为不可信，越出条目目录的路径被拒绝。事件：`progress`（字节）、`itemDone`、`itemError`（`unavailable` / `storage` / `connection`）、`done`；账号没有 Wallpaper Engine 时 `error: notOwned` 结束整批。

## 组件与凭据边界

- Swift 主应用：`SteamAccountSession` 管理会话、请求串行化和单次续签；`SteamKeychain` 原子更新持久令牌；`SteamLoginView` 展示二维码和兼容入口。
- 自有 helper：`helpers/ScenaSteamService`，基于 SteamKit2 3.4.0 和 .NET 10。使用 Steam WebSocket CM 连接，按需执行一次扫码或恢复操作，然后退出。源码及依赖锁文件留在仓库。
- 私有 stdin/stdout 使用协议 v1 的逐行 JSON，携带请求 ID。输入方法为 `qr`、`restore`、`ping`；输出事件包括 `ready`、`connecting`、`qr`、`result`、`error`。二维码只接受 Steam 挑战域名。没有监听网络端口。
- Refresh token 仅在主应用钥匙串和认证时的进程内存/管道中传递；不放入命令行、UserDefaults、普通文件或日志。access token 和社区 Cookie 只驻留内存。错误输出使用受控代码，不回显异常内容或认证响应。
- 钥匙串 service 为 `<当前 bundle ID>.steam.auth.v1`，使用 macOS 登录钥匙串，不要求额外 provisioning profile。测试预览版使用独立 bundle ID，不共享正式版凭据。
- 自定义非零 LoginID 保存在偏好设置，刷新合并为一个进行中的任务。账号切换、取消和退出登录均使用代次校验，旧任务不能覆盖新账号。退出登录的持久标记阻止删除凭据失败后的自动恢复。
- 社区请求只向 Steam Community 发送 Cookie，拒绝跨域重定向。401/403 或登录页面只尝试续签一次；重试同时替换 Cookie 和表单 CSRF sessionid。重复权限拒绝不会误判为持久凭据撤销。
- 取消或超时终止子进程，必要时延迟强制终止；父进程关闭 stdin 后 helper 也取消工作。

## 构建与签名

安装 `global.json` 指定的 .NET SDK 和 Python 3，执行：

```bash
bash scripts/build-steam-service.sh
xcodebuild -project wallhaven.xcodeproj -scheme wallhaven -configuration Debug build
```

`SCENA_DOTNET` 可指定 SDK 可执行文件。构建使用锁定依赖，生成自包含 `osx-arm64` / `osx-x64` 产物、许可通知、源码指纹和输入输出文件清单。产物位于忽略的 `build/steam-service/`；清理该目录后必须先重新生成，不能直接运行 Xcode 构建。

Xcode 的嵌入阶段检查源码指纹，复制组件到 `Scena.app/Contents/Resources/SteamService/`，为原生二进制逐项签名。helper 单独具有 `allow-jit` entitlement；主应用维持 Hardened Runtime 和脚本沙箱。文件清单为脚本提供明确的读写边界。发布脚本自动先构建组件。

SteamKit、传递依赖及 .NET 的许可和通知文件随应用分发。本机 Release `.app` 约 212 MiB，其中双架构认证组件约 175 MiB（未压缩）；普通用户无需另装 .NET。当前未裁剪运行时，以保留协议序列化所需的反射行为。

## 已完成验证与边界

- 100 项单元测试通过，包含参数化用例的实际运行数为 102。覆盖真实测试钥匙串读写、令牌轮换、恢复单飞、取消/退出竞争、Cookie 校验、HTTP 续签边界和 helper 协议/超时/强制终止。用例使用隔离偏好设置及假凭据，不读取真实账号令牌。
- Debug 测试和 Release 双架构编译通过，主应用最低版本为 macOS 14.0，Release 完整签名校验通过。两种架构的自包含 helper 都完成 `ping`；真实 Steam 网络二维码挑战已验证。
- 用户在独立预览版中实际扫码成功，同步 78 个订阅。完全退出并确认主进程及 helper 不再运行后重新启动，无需再次扫码恢复登录，再次同步到 78 个订阅。预览版自动下载始终关闭，正式安装版未被替换。
- 测试主机为 Apple 芯片、macOS 27.0.1。Intel helper 在 Rosetta 下运行通过，尚未完成 Intel Mac 或 macOS 14 实机测试；未执行真实账号的订阅/退订写操作、服务端撤销授权及长期跨版本签名升级测试。
- 尚未接入原生 CDN 下载、系统代理热切换或场景离线烘焙，也不承诺令牌固定有效期或所有地区网络连通。
