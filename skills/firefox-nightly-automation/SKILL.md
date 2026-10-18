---
name: firefox-nightly-automation
description: 在 Windows 以 Agent full access 启动 Firefox Nightly，连接已有浏览器执行 Puppeteer 任务，或自动永久安装 XPI。默认开启 Remote Control 并批准本次原生连接确认框。支持明确授权的会话重置。
---

# Firefox Nightly automation

入口为工具根目录的 `cli.mjs`。先从本 SKILL.md 所在目录解析目录联接的真实位置，再向上两级取得工具根目录。可用下列命令，将参数替换为当前 skill 目录的绝对路径：

```powershell
node -e "const fs=require('node:fs'),p=require('node:path');console.log(p.resolve(fs.realpathSync(process.argv[1]),'../..'))" '<当前skill目录绝对路径>'
```

核对根目录存在 `cli.mjs` 和 `package.json`，之后以其绝对路径调用。定义见工具根目录的 GLOSSARY.md；调用及实测边界见 README.md 和 VALIDATION.md。

启动 Nightly 默认使用工具根目录的 `scripts/start-nightly.ps1`：`pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '<工具根目录>/scripts/start-nightly.ps1'`。启动器只为 Firefox 子进程设置 `MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1`，即本工具的 Agent full access，支持已授权的 `about:` / `moz-extension:` 内部页任务。先检查已有浏览器；普通连接继续复用现有进程。启动变量不能为已运行进程补权，调试会话重置也不会改变它；现有进程拒绝内部页时，应报告需要带权限重新启动，只有用户已授权正常退出重开时才执行。完整启动参数和任务栏快捷方式见 `docs/reference.md` 的“默认启动权限”。

用户已授权本工具默认直接开启已有 Nightly 的 Remote Control，无需再次确认或要求用户手动开启。2026-10-17 明确补充：用户要求使用、开启或连接 Firefox Remote Control，就同时授权 Agent 自行完成服务开启和本次连接的原生 Allow 确认；不得把同一连接的开启与确认拆成两次权限提问，也不要求用户手动点击。直接使用 `run` 或 `start` 的默认自动确认流程。

接受开启服务的原生工具栏、面板操作及已匹配的本次连接确认框引起的目标窗口激活；页面任务继续在后台执行。历史“后台操作”要求本身不撤销上述连接准备授权；只有用户在当前任务明确禁止服务开启/确认框激活或自动确认时，才按该次限制执行。连接授权不代替发送消息、安装扩展、写入存储等业务任务的授权；已有任务授权则持续执行，不为每个必要步骤反复确认。仅计划或讨论时不实际连接。

先 `node '<入口>' status`。选择明确的已有 Nightly；多窗口时指定实际 HWND。不要启动替代浏览器、刷新现有页面或更改 Firefox profile。

优先 `node '<入口>' run --task '<绝对路径 task.mjs>'`。模块默认导出异步函数，接收 Puppeteer browser，通过公开 API 执行当前任务授权的后台操作。按完整 URL/标题确认任务目标，不切换可见标签，不调用 browser.close()。模块无代码沙箱，不能执行来源不明的任务文件。

创建独立后台测试窗口、排查内部页导航超时，或核验安装后的输入/图像效果时，先读工具根目录的 [docs/background-acceptance.md](../../docs/background-acceptance.md)。其中规定自建页面的归属识别、就绪检查、可信输入与清理，以及分步通过但最终守卫失败时的报告方式。原生控件失败时读 [原生控件诊断](../../docs/reference.md#原生控件诊断)，按 lastControlState 区分禁用、屏幕外与缺少 InvokePattern。

用户要求安装扩展时，默认 `node '<入口>' install --xpi '<绝对路径.xpi>'`：读取清单与散列，自动批准自己的连接，通过 moz:permanent=true 安装归档，并核对 ID、版本、启用及非临时状态。不再默认调用 browser.installExtension() 临时加载。Nightly 未签名包要求用户已配置 xpinstall.signatures.required=false；不自行修改偏好，不先卸载或失败后回退临时加载。

检查 data.installation.status：active 才表示正式副本已启用；restart-required 表示永久归档已安装，旧临时副本仍占位，需要正常重启 Nightly 后再执行安装完成核验。用户已经明确授权浏览器重启时，直接执行正常应用内重启并核验，不再次询问同一权限；普通 install 不自行重启。保留临时副本和存储，不自动卸载。浏览器重启与调试会话重置是不同动作，重启授权不扩大其他窗口操作权限。completedStages 的 addon-archive-installed 与 addon-installed 分别表示归档接受和正式副本启用；不要把待重启或后续后台检查失败说成已完全可用。具体收据和错误见 README 的“默认 XPI 安装”。

单独开关用 `start / stop`。`start` 通过实际连接验证并保留服务；`stop` 仅关闭工具拥有的同一代服务。`run` 自动同意自己的连接，结束后断开客户端，仅关闭本次新开启的服务。其他连接器/MCP 会另建会话，需要各自授权流程，不能把一次批准理解成所有客户端都已获准。

用户明确要求重置当前调试会话时，优先用 `reset-session --reset-existing`：通过 Mozilla 官方 Marionette 传输清除共享会话，保留服务、浏览器和窗口。`restart --reset-existing` 会随后尝试新连接；新授权失败时 completedStages 表明重置是否已经完成。不要把 session-reset 说成服务或浏览器进程重启。普通任务不能自动使用这些入口清除其他客户端；已有明确重置指令时不再重复询问许可。

用户要求服务关闭重开时用 `restart --reset-existing --restart-service`。它通过原生面板后台关闭并重开 Remote Control，不重启浏览器进程；最小化或后台不可用时报告失败。只用连接元数据示例测试工具时：`run --task '<工具根目录>/examples/browser-status.mjs'`。

当前 Nightly 160.0a1 的原生 Allow 会产生前台事件；这属于本次连接确认框的默认许可，与开启服务的窗口激活例外分别检查。consentAutomationAvailable=true。只匹配 Nightly 中桌面顶层或浏览器直接子节点的原生确认框，并核对完整说明、Allow/Deny 和未勾选复选框；拒绝已有或多个确认框。始终不勾选记住决定、不关闭授权偏好、不使用坐标或 OS 键鼠。

读取 JSON 的 `ok`、退出码、`handshake`、`consent.seen/invoked/closed` 和 `background`，不要把端口监听、Invoke 被调用、离线测试当成真实验收通过。foregroundStable、foregroundWithinControlPolicy、foregroundWithinConsentPolicy 保留原始前台观察；browserForegroundWithinControlPolicy 判断连接准备的焦点例外。用户切换其他应用只记录，不阻止连接。首次原生动作或连接前，工具内部最多采样四次，取得连续稳定的窗口与选中标签后锁定检查基线；此前用户切换标签或调整窗口可被采纳，不归因于工具。锁定后不重新采纳变化，不自动重放动作或页面任务。

标签使用 tab strip 内唯一 AutomationId，无唯一 ID 时使用选中位置；UIA Runtime ID 变化仅反映在 tabProviderIdentityStable，不单独判定切换。clipboardPolicy=observe-only，clipboardStable=false 仅表示剪贴板序号变化，不能据此中止或宣称工具写入。任务仍须按完整 URL/标题确认目标；不要用标签位置代替业务目标校验。完成后 consentFocusActive 和 serviceStartFocusActive 应为 false。

`F_DESKTOP_UNSTABLE` 表示四次准备采样仍无法取得连续稳定状态，工具尚未执行原生动作；报告准备未完成，不循环重试。`F_DESKTOP_CHANGED` 表示锁定后检测到窗口集合、位置、最小化、选中标签或未授权的目标浏览器焦点变化；优先读取 background.lastFailure.reasons，区分 window-set、window-position、window-minimized、tab-selection、browser-focus，不笼统声称窗口和标签都变了。当前 desktopChanges 是最新观察，lastFailure 保留触发时原因。保留错误，不强行恢复窗口或清除其他会话。原始报告位于 `.local/runs/`，不收集页面内容或凭据。
