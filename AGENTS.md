# Firefox Nightly automation

本工具用于已有 Firefox Nightly 的运行时 Remote Control，代码入口是 `cli.mjs`。源码职责与调用方式见 README.md。

术语见 GLOSSARY.md。主窗口、Remote Control 面板和原生连接确认框是三个不同对象；涉及激活权限时必须区分。

- 代码发现优先使用 codebase-memory-mcp，索引名 `firefox-nightly-automation`；索引缺失时先索引当前目录。PowerShell/C# 覆盖不足时可读取文件。
- 默认直接开启已有 Nightly 的 Remote Control，无需另行确认；允许开启服务的原生控件操作引起目标主窗口激活。本次连接的原生确认框也默认允许激活并自动点击 Allow。页面任务及关闭服务继续遵守后台约束；最小化或原生控件不可用时报告失败，不自行恢复窗口。用户在当前任务明确要求严格后台时，以该要求为准。不得使用 OS 键鼠、剪贴板写入、重启 Firefox 或关闭浏览器作为回退。
- 普通网页不能用作原生面板或授权框。只处理本工具这次连接产生的原生授权框，不勾选记住决定。普通任务不关闭其他连接；用户明确要求重置当前 Remote Control/调试会话时，才使用 `restart --reset-existing`。
- 离线检查：`npm test`，使用 PowerShell parser 检查 `src/native.ps1`。真实浏览器测试与离线测试分别报告。
- 测试示例只读取浏览器元数据。用户页面业务操作需要该任务本身授权。
- 用户授权安装扩展时，默认 `node cli.mjs install --xpi '<绝对路径.xpi>'` 永久安装；只有明确要求临时测试才临时加载。检查 installation.status：active 才表示版本正确、启用且非临时；restart-required 表示归档已装入、临时副本仍占位。正常重启后重试，不自动重启或卸载临时副本清理数据。不改签名偏好，不回退临时安装。包已安装后的其他失败须检查 completedStages，避免误报未发生安装。
- 私有诊断、服务归属和运行报告写入忽略的 `.local/`，不记录页面内容或凭据。
- 用户要求使用、开启或连接 Remote Control，默认包含 Agent 自动开启服务和批准本次连接的原生 Allow，不拆分权限提问。连接准备与页面业务权限分别判断，已有业务授权不逐步重问。
- 原始全桌面前台事件继续报告；`browserForegroundWithinControlPolicy` 对目标 Nightly 判断焦点例外。首次原生动作或连接前最多四次稳定采样，随后锁定基线；锁定后不采纳变化、不重放动作或任务。窗口与选中标签比较集中在 `src/desktop-policy.ps1`，不比较无序 JSON。
- 标签以 tab strip 内唯一 AutomationId 或选中位置识别，Runtime ID 仅诊断；剪贴板序号是 observe-only，用户复制内容不阻止连接。任务必须独立复核完整 URL/标题。失败依据 lastFailure.reasons，不能把 clipboardStable=false 或 Runtime ID 变化当作操作失败。
- 需要 Node 22.12+ 与 PowerShell 7；用 `npm ci --ignore-scripts --cache .local/npm-cache` 安装锁定依赖。
- 会话重置使用本目录 .venv 的 Mozilla marionette-driver；requirements.txt 锁定版本/哈希。`reset-session --reset-existing` 只有明确重置授权时调用。
- 焦点变化例外分别覆盖开启 Remote Control 和已匹配本次连接确认框。锁定后的窗口集合、位置、最小化、选中标签及区间外目标浏览器焦点变化仍会失败。foregroundWithinControlPolicy、foregroundWithinConsentPolicy 保留从初始化开始的原始检查；操作检查从稳定基线的事件索引开始，原始事件不删除。Prepare-Desktop 不得覆盖已有原生操作或确认框区间。
- `restart --reset-existing` 默认清除共享会话；加 `--restart-service` 才关闭并重开原生 Remote Control 服务。普通任务不可用重置命令清除其他客户端；已有用户重置授权时不重复询问。
- Python 传输回归：`.venv/Scripts/python.exe tests/session_reset_test.py`，只使用本机临时 TCP fixture，不连接真实浏览器。
