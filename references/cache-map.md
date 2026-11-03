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
| `%LOCALAPPDATA%\Google\Chrome\User Data\*\Login Data` | 保存的密码 | 🚫 | 密码库，永不触碰 |
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

## 4. 通讯 / 办公

| 路径 | 是什么 | 等级 | 说明 |
|---|---|---|---|
| `%USERPROFILE%\Documents\xwechat_files\*\cache` | 微信缓存目录 | ✅ | 需先退出微信；大头只走 微信→设置→通用→存储空间 |
| `%USERPROFILE%\Documents\xwechat_files\*\msg` | 聊天媒体 attach/file/video | 🚫 | 你收到的文件，删了就没了。走应用内存储空间清理 |
| `%USERPROFILE%\Documents\xwechat_files\*\db_storage` | 消息数据库 | 🚫 | 聊天记录本体 |
| `%USERPROFILE%\Documents\WeChat Files\*\FileStorage\Cache` | 微信缓存目录 | ✅ | 需先退出微信 |
| `%USERPROFILE%\Documents\WeChat Files\*\FileStorage\File` | 收到的文件 | 🚫 | 删了就没了 |
| `%APPDATA%\Telegram Desktop\tdata` | 会话与媒体缓存 | 🚫 | 设置→高级→数据与存储→清除缓存 |
| `%APPDATA%\DingTalk\log` | 运行日志 | ✅ |  |
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

