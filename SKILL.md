---
name: win-raccoon
description: >
  Windows 缓存清理体检（小浣熊 Win 版）：只读体检开发工具/应用/系统缓存，按安全等级判断可删项，确认后执行清理。
  Use when: 磁盘满了、清 C 盘、缓存瘦身、某应用占几十 G、cache cleaner。
  只管缓存，不卸载应用、不清注册表、不做系统调优。
---

# 小浣熊 Win 版 🦝 清理工作手册

浣熊吃东西之前，会先洗一洗。你删文件之前，先跑体检。

缓存地图不再是手写文档，而是机器可读的 `tools/cache-map.jsonl`（一行一条），
由 `tools/raccoon-scan.ps1` 对着本机实测，`references/cache-map.md` 是它的渲染产物。

## 铁律（违反任何一条就停下来）

1. **第一轮只读。** 只用 `raccoon-scan.ps1` 收集信息，输出报告。用户没确认之前，一个字节都不删、不移。
2. **地图优先。** 删除任何路径前，先查 `tools/cache-map.jsonl`。地图上没有的路径：用 `-Probe` 分类，查官方文档或源码，确认是"可再生缓存"且不在禁止清单里，才可以提交给用户。查不清楚就报告为"未知，不建议动"。
3. **状态神圣。** 登录态、消息数据库、聊天记录、收到的文件/图片/视频、浏览器密码与历史、`%APPDATA%` 里的配置、`Documents` 下的用户文件，永远不碰。只动"删掉后应用会自动重新生成或重新下载"的东西。
4. **先退场再动手。** 目标应用正在运行就先退出：先 `taskkill /IM app.exe`（优雅），等 2 秒还活着再 `taskkill /IM app.exe /F`。便携版应用按安装路径精准定位进程（如 `Get-Process | ? { $_.Path -like '*便携目录*' }`），避免误杀同名正式版。
5. **可恢复优先。** 清理目标所在盘的 `.raccoon-trash\<yyyyMMdd-HHmm>-<名称>\`（`Move-Item`，同盘秒移；跨盘会复制，提前告知）。用户确认战果后再清空 trash。不要直接 `Remove-Item -Recurse`；也不要把几十 GB 塞进回收站（超配额会被系统直接永久删除）。系统级路径（`C:\Windows\...`）需要管理员：生成命令让用户自己在管理员 PowerShell 里跑，不代跑。
6. **删除前报数。** 报告里每项写清楚：路径、大小、属于什么应用、安全等级、删除后果。让用户勾选。

## 工具

```powershell
# 体检：实测地图里每条路径，输出 METRIC 行
powershell -File tools/raccoon-scan.ps1

# 体检 + 最大的 N 项
powershell -File tools/raccoon-scan.ps1 -Top 25

# 机器可读报告
powershell -File tools/raccoon-scan.ps1 -Json > report.json

# 地图外路径分类（第 5 节流程的自动化）
powershell -File tools/raccoon-scan.ps1 -Probe "C:\Some\Unknown\Dir"

# 发现未收录的大目录 / 大文件
powershell -File tools/raccoon-scan.ps1 -Discover -MinMB 100 -Top 30
powershell -File tools/raccoon-scan.ps1 -BigFiles -MinMB 100 -Top 30

# 从 JSONL 重新生成 references/cache-map.md
powershell -File tools/raccoon-scan.ps1 -Render

# 安全闸门：策略、独立复测、只读检查、探针准确率
powershell -File tools/raccoon-validate.ps1

# 清理：把 safe 项移进同盘 .raccoon-trash（可恢复，不直接删）
powershell -File tools/raccoon-clean.ps1 -DryRun          # 先看清单
powershell -File tools/raccoon-clean.ps1                  # 真移
powershell -File tools/raccoon-clean.ps1 -Ids npm-cache   # 只清指定项
powershell -File tools/raccoon-clean.ps1 -IncludeCaution   # 连 caution 项一起移（默认只移 safe）
# 确认战果后清空 trash：cmd /c rmdir /s /q %USERPROFILE%\.raccoon-trash
```

`-Throttle`（默认 16）控制并行测量线程数。实测 16 是拐点：1→38 s，8→21 s，
16→8 s，24→10 s，32→13 s。再高就是磁盘元数据争用。
`-NoMeasure` 跳过体积实测，只出条目与存在性——地图改完想快速看结构时用。

## 工作流

### 第一轮：体检（只读）

```powershell
powershell -File tools/raccoon-scan.ps1 -Top 25
```

输出 `safe_gb` / `caution_gb` / `forbidden_gb` 与最大的若干项。
`-Discover` 找未收录的大目录，`-BigFiles` 找未收录的大安装包——
目录级发现会漏掉单个大文件，实测漏过 1.4 GB 的 `installer.exe`。

### 第二轮：判断

- ✅ 安全：可再生缓存，直接可清
- ⚠️ 注意：部分可清（写明只清哪个子目录、保留哪个）
- 🚫 别碰：说明为什么

### 第三轮：确认与执行

1. 输出报告，等用户勾选。
2. 退出目标应用（铁律 4）。
3. 按地图范围移入 `.raccoon-trash`；系统级路径给用户管理员命令。
4. 复测 `raccoon-scan.ps1` 与 `Get-PSDrive`，报战果；等用户确认后清空 trash。
5. 提醒重建成本：浏览器缓存下次开网页慢一次；Gradle/Maven/npm 重下依赖；JetBrains 索引重建 10-30 分钟；着色器缓存首启卡顿。

## 地图条目格式

`tools/cache-map.jsonl`，一行一个 JSON 对象：

```json
{"id":"npm-cache","section":"3. 开发工具","path":"%LOCALAPPDATA%/npm-cache","level":"safe",
 "app":"npm","kind":"package-cache","desc":"npm 包缓存","note":"npm cache clean --force",
 "regenerable":true,"source":"https://docs.npmjs.com/cli/v10/commands/npm-cache",
 "evidence":"tarball 缓存，重下即可","admin":false}
```

- `path` 用正斜杠，支持 `%ENV%` 与 `*` 通配。
- `level` 只能是 `safe` / `caution` / `forbidden`。
- `safe` 必须带 `regenerable: true`、`source`、`evidence`（≥6 字）。
- `measure: false` 表示只登记不测量——用于几十 GB 的禁止目录，避免拖慢体检。
- 同一等级的两条路径不能互相嵌套，否则重复计数（`raccoon-validate.ps1` 会拦）。

## 实战经验（已验证）

- **`D:\temp` 是陷阱**：名字像临时目录，实测 14.5 GB 全是活项目（pet-image-3d、EVOMAP、seed-bank、ReadBook、aDrive、frontend）。按名字清会毁掉工作。地图里标 `forbidden`。
- **旧地图不只是不全，是错的**：pnpm 的 store 是 `pnpm/package-manager-store` 不是 `pnpm/store`；钉钉日志是 `holmeslogs`/`recordLog`/`updaterlogs` 不是 `log`；Chrome 的密码文件是 `Login Data For Account`。对着本机核，别信文档。
- **`*-updater/installer.exe` 是纯浪费**：electron-updater 装完不删安装包。一条 glob 覆盖 qianfan/mmx/apifox/podman/zcode/sand/autoglm，实测 1.4 GB。
- **VS/SDK 安装残留**：`%TEMP%` 下随机名目录（内含 `Win11SDK_*`、`Microsoft.*_*`），单个可达 4.6GB，安装完成后即废弃，✅ 可整移；被占用的 mv 失败自动留下。
- **微信 4.x 数据**：存储路径常被重定向（本机在 `%APPDATA%\Tencent\xwechat`，不在 `Documents\xwechat_files`）；`msg/attach|file|video` 是聊天媒体 🚫，只能走微信内置"存储空间"清理。`radium/web` 是 LevelDB，也是 🚫。
- **整目录 mv 失败 = 有进程握着句柄**（哪怕 tasklist 看不到）：退一级改成"逐项搬移"，搬得动多少是多少，剩余下轮再收。
- **MSYS du 挂起 ≠ 有问题**：先换 robocopy 再下结论。
- **JetBrains 索引**：`%LOCALAPPDATA%\JetBrains\<IDE><版本>\{index,caches,log,tmp,jcef_cache,compile-server,full-line}` 可清但重建慢；`plugins` 和 `%APPDATA%\JetBrains` 配置永远不碰。
- **pnpm store**：可能有多个（C 盘 + D 盘），`pnpm store path` 确认在用哪个。

## 与扫描工具的关系

Windows 上可用 WizTree / TreeSize Free（图形）或 gdu（终端）快速定位大头，但**删除决策仍然走本 skill 的缓存地图与确认流程**。扫描工具的清单是参考，不是授权。

系统级官方入口（推荐用户自己跑）见 `references/cache-map.md` 第 6 节。
