# Windows 缓存地图（win-raccoon）

> 本文件由 `tools/raccoon-scan.ps1 -Render` 从 `tools/cache-map.jsonl` 生成，不要手改。
> 等级：✅ 安全（可再生，直接可清）｜⚠️ 注意（只清指定子目录/需权衡）｜🚫 别碰
> 所有删除动作：先移入所在盘的 `.raccoon-trash\`；系统级路径交给用户在管理员 PowerShell 执行。

## 1. 系统临时与诊断

| 路径 | 是什么 | 等级 | 说明 |
|---|---|---|---|
| `%LOCALAPPDATA%\Temp` | 用户临时文件；含 VS/SDK 安装 payload 残留 | ✅ | 被占用的文件 mv 失败自动留下，占用即安全 |
| `C:\Windows\Temp` | 系统临时文件 | ✅ | 需管理员；Remove-Item windir/Temp/* -Recurse -Force -EA SilentlyContinue |
| `C:\Windows\SoftwareDistribution\Download` | Windows 更新安装包缓存 | ✅ | 需管理员；先 Stop-Service wuauserv,bits，清完再 Start-Service |
| `C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization` | 传递优化 P2P 缓存 | ✅ | 需管理员；优先用 Delete-DeliveryOptimizationCache -Force |
| `C:\Windows.old` | 旧系统备份 | ⚠️ | 需管理员；只用 磁盘清理/存储感知 删；删后无法回退系统 |
| `C:\Windows\Prefetch` | 启动预读 | ⚠️ | 需管理员；能删但没必要，短期变慢 |
| `C:\Windows\WinSxS` | 组件存储 | 🚫 | 需管理员；禁止手删！只允许 Dism.exe /Online /Cleanup-Image /StartComponentCleanup |
| `C:\Windows\LiveKernelReports` | 内核实时转储 | ✅ | 需管理员；诊断残留 |
| `C:\Windows\Minidump` | 蓝屏小转储 | ✅ | 需管理员；诊断残留 |
| `%LOCALAPPDATA%\CrashDumps` | 应用崩溃转储 | ✅ |  |
| `%LOCALAPPDATA%\Microsoft\Windows\WER` | 错误报告队列 | ✅ |  |
| `C:\ProgramData\Microsoft\Windows\WER` | 错误报告队列（机器级） | ✅ | 需管理员； |
| `%LOCALAPPDATA%\Microsoft\Windows\Explorer` | 缩略图/图标缓存 thumbcache_*.db、iconcache_*.db | ⚠️ | 先结束 explorer.exe（自动重启）；收益一般 |
| `%LOCALAPPDATA%\D3DSCache` | D3D 着色器缓存 | ✅ | 游戏/3D 首次启动重编译会卡一下 |
| `%LOCALAPPDATA%\NVIDIA\DXCache` | NVIDIA DX 着色器缓存 | ✅ | 首启卡顿 |
| `%LOCALAPPDATA%\NVIDIA\GLCache` | NVIDIA GL 着色器缓存 | ✅ | 首启卡顿 |
| `%LOCALAPPDATA%\Microsoft\Windows\INetCache` | WinINet 遗留网络缓存 | ✅ |  |

## 2. 浏览器

| 路径 | 是什么 | 等级 | 说明 |
|---|---|---|---|
| `%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache` | HTTP 缓存 | ✅ | 先退出 Chrome；登录态在 Cookies，没动 |
| `%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache` | V8 编译缓存 | ✅ | 先退出 Chrome |
| `%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache` | GPU 着色器缓存 | ✅ | 先退出 Chrome |
| `%LOCALAPPDATA%\Google\Chrome\User Data\*\Service Worker\CacheStorage` | Service Worker 缓存 | ⚠️ | 离线站点资源会重下 |
| `%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache` | HTTP 缓存 | ✅ | 先退出 Edge |
| `%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache` | V8 编译缓存 | ✅ | 先退出 Edge |
| `%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache` | GPU 着色器缓存 | ✅ | 先退出 Edge |
| `%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2` | HTTP 缓存 | ✅ | 先退出 Firefox |
| `%LOCALAPPDATA%\Google\Chrome\User Data\*\Login Data*` | 保存的密码（Login Data / Login Data For Account） | 🚫 | 密码库，永不触碰 |
| `%LOCALAPPDATA%\Google\Chrome\User Data\*\Network\Cookies` | 登录态 Cookie | 🚫 | 删了全部站点掉登录 |
| `%LOCALAPPDATA%\Google\Chrome\User Data\*\History` | 浏览历史 | 🚫 | 用户数据 |

## 3. 开发工具

| 路径 | 是什么 | 等级 | 说明 |
|---|---|---|---|
| `%LOCALAPPDATA%\npm-cache` | npm 包缓存 | ✅ | npm cache clean --force；以 npm config get cache 为准 |
| `%LOCALAPPDATA%\pnpm\store` | pnpm 内容寻址存储 | ✅ | pnpm store prune；可能有多个，pnpm store path 确认 |
| `%LOCALAPPDATA%\Yarn\Cache` | yarn 包缓存 | ✅ | 重下即可 |
| `%LOCALAPPDATA%\pip\cache` | pip wheel/HTTP 缓存 | ✅ | pip cache purge |
| `%LOCALAPPDATA%\uv\cache` | uv 包缓存 | ✅ | uv cache clean |
| `%USERPROFILE%\.conda\pkgs` | conda 包缓存 | ✅ | conda clean --all |
| `%USERPROFILE%\.nuget\packages` | 全局包文件夹 | ⚠️ | dotnet nuget locals all --clear；内网私服注意同 Maven |
| `%LOCALAPPDATA%\NuGet` | NuGet 本地缓存 | ⚠️ | dotnet nuget locals all --clear |
| `%USERPROFILE%\.m2\repository` | 本地仓库 | ⚠️ | 不要整删：先只删 *.lastUpdated。整删=所有依赖重下，私服 snapshot 可能拿不回 |
| `%USERPROFILE%\.gradle\caches` | 依赖与构建缓存 | ⚠️ | 整删=重下全部依赖 |
| `%USERPROFILE%\.gradle\wrapper\dists` | Gradle 发行版下载 | ✅ | 旧版本发行版可删 |
| `%LOCALAPPDATA%\go-build` | Go 构建缓存 | ✅ | go clean -cache |
| `%USERPROFILE%\go\pkg\mod` | Go 模块缓存 | ⚠️ | go clean -modcache 后重新拉取 |
| `%USERPROFILE%\.cargo\registry` | crates.io 缓存 | ✅ | 重下即可 |
| `%USERPROFILE%\.cargo\git` | git 依赖检出 | ✅ | 重下即可 |
| `%USERPROFILE%\.cache\huggingface` | 模型权重缓存 | ⚠️ | 重下可能几十 GB，确认不需要离线再删 |
| `%USERPROFILE%\.cache\torch` | torch hub 预编译包 | ✅ | 重下预编译包 |
| `%LOCALAPPDATA%\ms-playwright` | 浏览器内核 | ✅ | 重装时重下 |
| `%USERPROFILE%\.cache\puppeteer` | Chromium 下载 | ✅ | 重装时重下 |
| `%USERPROFILE%\scoop\cache` | 安装包缓存 | ✅ |  |
| `%LOCALAPPDATA%\Docker\wsl` | Docker 的整个数据盘 vhdx | 🚫 | 正确流程：docker system prune → wsl --shutdown → 收缩 vhdx |
| `%LOCALAPPDATA%\Packages\*\LocalState\ext4.vhdx` | WSL 发行版磁盘 | 🚫 | 里面是整个 Linux 系统；进 WSL 清理后再收缩 vhdx |
| `%APPDATA%\Code\Cache` | Electron 缓存 | ✅ | 先退出 VS Code |
| `%APPDATA%\Code\CachedData` | V8 编译缓存 | ✅ | 先退出 VS Code |
| `%APPDATA%\Code\Code Cache` | V8 代码缓存 | ✅ | 先退出 VS Code |
| `%APPDATA%\Code\GPUCache` | GPU 缓存 | ✅ | 先退出 VS Code |
| `%APPDATA%\Code\logs` | 运行日志 | ✅ |  |
| `%USERPROFILE%\.vscode\extensions` | 已装扩展 | 🚫 | 删了要重装 |
| `%APPDATA%\Code\User` | 配置与快捷键 | 🚫 | 用户配置 |
| `%LOCALAPPDATA%\JetBrains\*\index` | 项目索引 | ⚠️ | 重建 10-30 分钟 |
| `%LOCALAPPDATA%\JetBrains\*\caches` | IDE 缓存 | ⚠️ | 重建慢 |
| `%LOCALAPPDATA%\JetBrains\*\log` | IDE 日志 | ✅ |  |
| `%LOCALAPPDATA%\JetBrains\*\tmp` | IDE 临时文件 | ✅ |  |
| `%LOCALAPPDATA%\JetBrains\*\jcef_cache` | 内嵌浏览器缓存 | ✅ |  |
| `%LOCALAPPDATA%\JetBrains\*\plugins` | 已装插件 | 🚫 | 删了要重装 |
| `%APPDATA%\JetBrains` | IDE 配置 | 🚫 | 用户配置 |
| `%LOCALAPPDATA%\Android\Sdk` | SDK 与 system-images | ⚠️ | 重下量大 |
| `%USERPROFILE%\.android\avd` | 模拟器数据 | 🚫 | 删了模拟器状态全丢 |
| `%USERPROFILE%\.platformio\packages` | 平台与工具链下载 | ✅ | 下次构建时重新下载；离线开发前先确认 |
| `%USERPROFILE%\.platformio\.cache` | PlatformIO 构建缓存 | ✅ |  |
| `%USERPROFILE%\.cache\codex-runtimes` | 下载的运行时（python/node 等） | ✅ | 下次运行自动重下 |
| `%USERPROFILE%\.codex\.tmp` | 临时文件 | ✅ |  |
| `%USERPROFILE%\.qoder\shared_client\index` | 代码索引（completion/git/graph/memory_*） | ⚠️ | 重建慢；删了首次打开项目要重新索引 |
| `%USERPROFILE%\.qoder\shared_client\cache` | 诊断转储与配额缓存 | ⚠️ | 含 machine_token.json（登录凭据），只清 diagnosis-*.bin |
| `%USERPROFILE%\.rustup\toolchains` | 已安装的 Rust 工具链 | ⚠️ | rustup toolchain uninstall 卸载不用的版本；整删=重下 |
| `%LOCALAPPDATA%\JetBrains\*\full-line` | 全行补全索引 | ⚠️ | 重建慢 |
| `%LOCALAPPDATA%\JetBrains\*\compile-server` | 编译服务器缓存 | ⚠️ |  |
| `%LOCALAPPDATA%\JetBrains\*\Maven` | IDE 侧 Maven 缓存 | ⚠️ |  |
| `%LOCALAPPDATA%\JetBrains\*\vcs-log` | VCS 日志索引 | ⚠️ |  |
| `%LOCALAPPDATA%\JetBrains\Daemon\bundles` | 后台守护进程运行时包 | ⚠️ |  |
| `%USERPROFILE%\.codex\plugins` | 已装插件 | ⚠️ | 删了要重装 |
| `%USERPROFILE%\.codex\sessions` | 会话记录 | ⚠️ | 历史对话，删了不可恢复 |
| `%USERPROFILE%\.codex\.sandbox-bin` | 沙箱二进制 | ⚠️ |  |
| `%USERPROFILE%\.qoder\shared_client\bin` | IDE 本体 | 🚫 | 程序文件 |
| `%LOCALAPPDATA%\pnpm\package-manager-store` | pnpm 内容寻址存储（实际路径） | ✅ | pnpm store prune；旧版在 pnpm/store |
| `%LOCALAPPDATA%\xiaohongshu-mcp\browser` | 下载的浏览器内核 | ✅ | 重装时重下 |
| `%USERPROFILE%\.local\node-v20.11.1-win-x64` | 下载的 node 运行时 | ✅ | 重下即可 |
| `%LOCALAPPDATA%\Packages\OpenAI.Codex_*\LocalCache` | UWP 应用本地缓存 | ✅ |  |
| `%LOCALAPPDATA%\Microsoft\VisualStudio\WebView2Cache` | WebView2 缓存 | ✅ |  |
| `%LOCALAPPDATA%\Microsoft\VisualStudio\Roslyn.bak_*` | Roslyn 缓存的历史备份 | ✅ | 升级时留下的旧副本 |
| `%APPDATA%\Noi\Partitions\*\Code Cache` | V8 代码缓存 | ✅ | 退出后清 |
| `%LOCALAPPDATA%\OpenAI\Codex\runtimes` | 下载的运行时 | ✅ |  |
| `%LOCALAPPDATA%\com.ccswitch.desktop\EBWebView\component_crx_cache` | 组件 CRX 缓存 | ✅ |  |
| `%USERPROFILE%\.pi\agent\sessions` | 会话记录 | ⚠️ | 历史对话，删了不可恢复 |
| `%USERPROFILE%\.pi\agent\npm` | pi 的 npm 依赖 | ⚠️ | 已装依赖 |
| `%APPDATA%\jdtls` | Java 语言服务器安装 | ⚠️ | 旧哈希版本可删，保留在用的那个 |
| `%APPDATA%\DingTalk\plugins` | 已装插件 | ⚠️ | 删了要重装 |
| `%LOCALAPPDATA%\opengrep` | 按版本安装的扫描器 | ⚠️ | 旧版本目录可删 |
| `%APPDATA%\Noi\Partitions` | Electron 分区数据 | ⚠️ | 只清其下 Code Cache |
| `%LOCALAPPDATA%\Microsoft\VisualStudio` | VS 用户级缓存与组件 | ⚠️ | 只清 WebView2Cache 与 Roslyn.bak_* |
| `%LOCALAPPDATA%\Packages\MicrosoftWindows.Client.CBS_*\LocalState` | Windows 外壳包状态 | ⚠️ | 系统组件，别手删 |
| `%USERPROFILE%\.cc-switch\backups` | 配置备份 | ⚠️ | 用户配置快照 |
| `%LOCALAPPDATA%\com.ccswitch.desktop\EBWebView` | WebView2 用户数据 | ⚠️ | 只清 component_crx_cache |
| `%USERPROFILE%\.minimax\v2` | sqlite 与会话 | ⚠️ | 会话记录不可恢复 |
| `%LOCALAPPDATA%\OpenAI\Codex\bin` | Codex 二进制 | ⚠️ | 程序文件 |
| `%USERPROFILE%\.qoder\bin\qodercli\qodercli-1.0.21.exe` | 旧版 CLI 二进制 | ✅ | 当前版本在用时，旧版本可删 |
| `%LOCALAPPDATA%\*-updater\installer.exe` | 各 Electron 应用已安装版本的安装包 | ✅ | 软件已装，安装包可删；覆盖 qianfan/mmx/apifox/podman/zcode/sand/autoglm |
| `%LOCALAPPDATA%\*-updater\pending` | 已下载待安装的更新包 | ✅ | 安装完成后即废弃 |
| `%USERPROFILE%\.codegraph\bundles` | 按版本下载的运行时 bundle | ✅ | 旧版本可删 |
| `%LOCALAPPDATA%\JetBrains\*\plugins\*.zip` | 插件安装包（已解压，zip 冗余） | ⚠️ | 解压后的插件目录才是本体；zip 可删但位于 plugins 内，需人工确认 |

## 4. 通讯 / 办公

| 路径 | 是什么 | 等级 | 说明 |
|---|---|---|---|
| `%USERPROFILE%\Documents\xwechat_files\*\cache` | 微信缓存目录 | ✅ | 需先退出微信；大头只走 微信→设置→通用→存储空间 |
| `%USERPROFILE%\Documents\xwechat_files\*\msg` | 聊天媒体 attach/file/video | 🚫 | 你收到的文件，删了就没了。走应用内存储空间清理 |
| `%USERPROFILE%\Documents\xwechat_files\*\db_storage` | 消息数据库 | 🚫 | 聊天记录本体 |
| `%USERPROFILE%\Documents\WeChat Files\*\FileStorage\Cache` | 微信缓存目录 | ✅ | 需先退出微信 |
| `%USERPROFILE%\Documents\WeChat Files\*\FileStorage\File` | 收到的文件 | 🚫 | 删了就没了 |
| `%APPDATA%\Telegram Desktop\tdata` | 会话与媒体缓存 | 🚫 | 设置→高级→数据与存储→清除缓存 |
| `%APPDATA%\DingTalk\holmeslogs` | 运行日志（holmeslogs/recordLog/updaterlogs） | ✅ | 三个日志目录都可清 |
| `%APPDATA%\DingTalk\DingpanSyncUpgrade` | 更新安装包 | ✅ |  |
| `%APPDATA%\DingTalk\DBFiles` | 消息数据库 | 🚫 | 聊天记录本体 |
| `%APPDATA%\LarkShell\update` | 更新安装包 | ✅ | 大头用 飞书→设置→存储空间 清理 |
| `%APPDATA%\LarkShell\aha\users` | 用户数据 | 🚫 | 会话与文件 |
| `%APPDATA%\discord\Cache` | Electron 缓存 | ✅ | 退出后清 |
| `%APPDATA%\discord\Code Cache` | V8 代码缓存 | ✅ | 退出后清 |
| `%APPDATA%\discord\GPUCache` | GPU 缓存 | ✅ | 退出后清 |
| `%APPDATA%\Slack\Cache` | Electron 缓存 | ✅ | 退出后清 |
| `%APPDATA%\Slack\Code Cache` | V8 代码缓存 | ✅ | 退出后清 |
| `%APPDATA%\Slack\GPUCache` | GPU 缓存 | ✅ | 退出后清 |
| `%LOCALAPPDATA%\Steam\htmlcache` | 内置浏览器缓存 | ✅ |  |
| `%APPDATA%\Microsoft\Teams\Cache` | Electron 缓存 | ✅ | 新版 Teams 在 %LOCALAPPDATA%/Packages/MSTeams_* |
| `%APPDATA%\Tencent\xwechat\log` | 客户端运行日志 | ✅ | 需先退出微信 |
| `%APPDATA%\LarkShell\sdk_storage\log` | SDK 运行日志 | ✅ |  |
| `%APPDATA%\qianfan-desktop-app\Cache` | Electron 缓存 | ✅ | 退出后清 |
| `%APPDATA%\qianfan-desktop-app\lightsandbox` | 沙箱运行时 git/node/python | ✅ | 下次启动重下 |
| `%LOCALAPPDATA%\ima.copilot\User Data\reshub` | 下载的资源包 | ✅ |  |
| `%LOCALAPPDATA%\ima.copilot\User Data\component_crx_cache` | 组件 CRX 缓存 | ✅ |  |
| `%APPDATA%\Tencent\xwechat\radium\users` | 小程序用户数据 | ⚠️ | 小程序登录态与本地存储 |
| `%APPDATA%\Tencent\WeMeet\Global` | 会议客户端数据 | ⚠️ | 应用内清理 |
| `%APPDATA%\LarkShell\sdk_storage` | SDK 存储（哈希目录） | ⚠️ | 大头用 飞书→设置→存储空间 清理 |
| `%APPDATA%\apifox\apifox-data` | 项目数据（接口集合） | ⚠️ | 云端有副本，但本地删了要重新同步 |
| `%APPDATA%\qianfan-desktop-app\qianfan_desk_xdg` | Electron 用户数据 | ⚠️ |  |
| `%LOCALAPPDATA%\ima.copilot\User Data\Default` | Chromium profile | ⚠️ | 只清其下 Cache/Code Cache/GPUCache |
| `%APPDATA%\LarkShell\iron\users` | 用户数据（消息与文件） | 🚫 | 大头用 飞书→设置→存储空间 清理 |
| `%APPDATA%\Tencent\xwechat\radium\web` | 小程序 LevelDB 存储 | 🚫 | 小程序本地存储，删了小程序状态全丢 |
| `%APPDATA%\Tencent\xwechat\XPlugin` | 插件二进制 | 🚫 | 删了要重装 |
| `%LOCALAPPDATA%\ima.copilot\Application` | 应用本体 | 🚫 | 程序文件 |

## 5. 用户目录与安装（别碰）

| 路径 | 是什么 | 等级 | 说明 |
|---|---|---|---|
| `%APPDATA%\npm` | 全局安装的 npm 包 | 🚫 | 这是已装软件，不是缓存；缓存是 %LOCALAPPDATA%/npm-cache |
| `%LOCALAPPDATA%\Programs` | 用户级安装的应用程序 | 🚫 | 程序文件 |
| `%USERPROFILE%\Downloads` | 下载目录 | 🚫 | 用户文件，不是缓存 |
| `%USERPROFILE%\Videos` | 视频目录 | 🚫 | 用户文件 |
| `C:\ProgramData\Package Cache` | VS/安装器包缓存 | 🚫 | 需管理员；卸载/修复要用，删了修复会失败 |
| `%APPDATA%\TinyTeX` | TeX 发行版 | 🚫 | 已安装的 TeX 环境 |
| `D:\temp` | 名字像临时目录，实际是项目工作区 | 🚫 | 实测 14.5 GB：pet-image-3d、EVOMAP、seed-bank、ReadBook、aDrive、frontend 等真实项目。按名字清会毁掉工作 |
| `D:\tmp` | 临时草稿目录 | ⚠️ | 脚本输出、分析中间文件；确认无用再清 |
| `D:\codingProjects` | 项目根目录（含构建产物） | ⚠️ | 只清各项目内 target/、build/、node_modules/、dist/，且需逐项目确认 |

## 6. 系统官方入口（优先推荐用户自己跑）

| 入口 | 说明 |
|---|---|
| 设置 → 系统 → 存储 → 临时文件 / 存储感知 | 官方一站式；⚠️ 别勾"下载" |
| `cleanmgr`（磁盘清理） | 含"以前的 Windows 安装""传递优化文件" |
| `Dism.exe /Online /Cleanup-Image /StartComponentCleanup` | 管理员；安全压缩组件存储 |
| `Delete-DeliveryOptimizationCache -Force` | 管理员 PowerShell |
| `Clear-RecycleBin -Force` | 清空回收站=真删，仅当用户明确要求 |

## 7. 地图外路径的处理流程

1. `raccoon-scan.ps1 -Probe <path>` 拿初判与理由。
2. 查官方文档/源码，确认是"可再生缓存"。
3. 不在禁止清单里 → 可以提议给用户；否则标"未知，不建议动"。
4. 确认后写进 `tools/cache-map.jsonl`，跑 `raccoon-validate.ps1` 过闸门。

