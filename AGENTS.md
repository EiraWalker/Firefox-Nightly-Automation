# Firefox Nightly automation

本工具用于已有 Firefox Nightly 的运行时 Remote Control，代码入口是 `cli.mjs`。源码职责与调用方式见 README.md。

术语见 GLOSSARY.md。主窗口、Remote Control 面板和原生连接确认框是三个不同对象；涉及激活权限时必须区分。

- 代码发现优先使用 codebase-memory-mcp，索引名 `firefox-nightly-automation`；索引缺失时先索引当前目录。PowerShell/C# 覆盖不足时可读取文件。
- 本次连接的原生确认框默认允许激活并自动点击 Allow，无需任何参数。主窗口和 Remote Control 面板始终严格后台，不主动激活主窗口或恢复最小化窗口；后台无法操作时报告失败。不得使用 OS 键鼠、剪贴板写入、重启 Firefox 或关闭浏览器作为回退。
- 普通网页不能用作原生面板或授权框。只处理本工具这次连接产生的原生授权框，不勾选记住决定。普通任务不关闭其他连接；用户明确要求重置当前 Remote Control/调试会话时，才使用 `restart --reset-existing`。
- 离线检查：`npm test`，使用 PowerShell parser 检查 `src/native.ps1`。真实浏览器测试与离线测试分别报告。
- 测试示例只读取浏览器元数据。用户页面业务操作需要该任务本身授权。
- 用户授权安装扩展时，默认 `node cli.mjs install --xpi '<绝对路径.xpi>'` 永久安装；只有明确要求临时测试才临时加载。检查 installation.status：active 才表示版本正确、启用且非临时；restart-required 表示归档已装入、临时副本仍占位。正常重启后重试，不自动重启或卸载临时副本清理数据。不改签名偏好，不回退临时安装。包已安装后的其他失败须检查 completedStages，避免误报未发生安装。
- 私有诊断、服务归属和运行报告写入忽略的 `.local/`，不记录页面内容或凭据。
- 需要 Node 22.12+ 与 PowerShell 7；用 `npm ci --ignore-scripts --cache .local/npm-cache` 安装锁定依赖。
- 会话重置使用本目录 .venv 的 Mozilla marionette-driver；requirements.txt 锁定版本/哈希。`reset-session --reset-existing` 只有明确重置授权时调用。
- 焦点变化例外仅覆盖已匹配原生确认框的处理区间，以及确认框关闭导致的浏览器焦点回返。区间之外继续检查后台约束；所有浏览器窗口位置、最小化状态、选中标签和剪贴板检查持续有效。不得把这项例外扩大为浏览器主窗口激活许可。原始前台事件仍保留。
- `restart --reset-existing` 默认清除共享会话；加 `--restart-service` 才关闭并重开原生 Remote Control 服务。普通任务不可用重置命令清除其他客户端；已有用户重置授权时不重复询问。
- Python 传输回归：`.venv/Scripts/python.exe tests/session_reset_test.py`，只使用本机临时 TCP fixture，不连接真实浏览器。
