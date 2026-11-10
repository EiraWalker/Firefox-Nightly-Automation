<div align="center">

# Firefox Nightly Automation

**让 AI Agent 使用你已打开的 Firefox Nightly。**

后台执行 Puppeteer 任务 · 管理 Remote Control · 永久安装 XPI

![Windows](https://img.shields.io/badge/Windows-0078D4?style=flat-square)
![Node.js](https://img.shields.io/badge/Node.js-%E2%89%A5%2022.12-339933?style=flat-square)
[![MIT](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)

[快速开始](#快速开始) · [Agent skill](#agent-skill) · [使用参考](docs/reference.md) · [验证记录](VALIDATION.md)

</div>

## 能做什么

| 功能 | 行为 |
| --- | --- |
| 启动浏览器 | 默认为 Nightly 子进程设置 `MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1`，支持已授权的内部页任务 |
| 连接现有浏览器 | 通过 WebDriver BiDi 连接已有 Nightly，沿用当前登录状态 |
| 执行 Agent 任务 | 默认独立后台工作窗口，用户其他窗口正常操作不打断页面任务 |
| 管理调试服务 | 按归属启停 Remote Control，支持明确授权的会话重置 |
| 永久安装扩展 | 从 XPI 安装或更新，核对版本、启用状态和非临时状态 |

## 快速开始

需要 **Windows、Node.js 22.12+、PowerShell 7**，以及已配置运行时 Remote Control 的 Firefox Nightly。当前原生适配器针对 **Nightly 160.0a1 英文控件**验证。

```powershell
git clone https://github.com/EiraWalker/Firefox-Nightly-Automation.git
Set-Location Firefox-Nightly-Automation
npm ci --ignore-scripts --cache .local/npm-cache

# 需要启动 Nightly 时，默认使用 Agent full access 启动器
pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ./scripts/start-nightly.ps1

# 查看已有浏览器和服务状态
node ./cli.mjs status

# 执行只读取浏览器元数据的示例
node ./cli.mjs run --task './examples/browser-status.mjs'
```

默认浏览器路径为 `C:\Program Files\Firefox Nightly\firefox.exe`，BiDi 端点为 `ws://127.0.0.1:9222/session`。可通过 `--executable`、`--port` 调整；多窗口时用 `--hwnd` 指定状态检查得到的目标。

Git Bash 或 Agent 后台进程应调用 `node.exe`，必要时使用解析后的绝对路径。某些 Git Bash 环境把 `node` 定义为 `winpty node.exe` 别名：前台可运行，后台没有 TTY 时却会在 CLI 启动前报 `stdin is not a tty`。先用 `type node` 区分 shell 别名与工具错误，不要因此重复申请浏览器连接。

启动器仅设置 Firefox 子进程的环境，不写入用户或系统全局环境变量。已运行的 Nightly 不会因再次调用启动器或重置调试会话而获得启动权限；需正常退出后通过启动器重新打开。启动器不会自动结束浏览器。任务栏快捷方式配置及验证边界见[默认启动权限](docs/reference.md#默认启动权限)。

## 常用命令

| 命令 | 用途 |
| --- | --- |
| `node ./cli.mjs status` | 只读查看状态，不建立调试连接 |
| `node ./cli.mjs run --task '<任务.mjs>'` | 准备连接、执行任务并清理 |
| `node ./cli.mjs start` | 开启并验证服务，保留服务供后续使用 |
| `node ./cli.mjs stop` | 关闭本工具拥有且归属仍有效的服务 |
| `node ./cli.mjs install --xpi '<扩展.xpi>'` | 永久安装或更新扩展 |
| `node ./cli.mjs verify --xpi '<扩展.xpi>'` | 对照本地包的 ID、版本，只读核验已安装的正式副本 |
| `node ./cli.mjs verify --id '<扩展 ID>'` | 不提供包时，只读核验指定扩展已启用且非临时 |

任务模块默认导出异步函数，接收任务范围的 `browser` 和 `workspace`；使用 `workspace.page` 操作工具自己的页面。结束时关闭自己的工作窗口、断开自己的连接，保留用户窗口和浏览器。默认允许仅创建工作窗口时短暂激活；当前任务不允许时加 `--no-workspace-activation`，不放宽后续检查。窗口归属、兼容范围及并行操作规则见[独立工作窗口](docs/task-workspace.md)。

<details>
<summary>会话重置</summary>

仅在明确授权重置当前调试会话时使用。先安装锁定的 Python 依赖，需要本机已有 `uv`：

```powershell
uv venv .venv --python 3.12
uv pip sync requirements.txt --python .venv/Scripts/python.exe --require-hashes

# 清除当前共享调试会话，保留服务与浏览器
node ./cli.mjs reset-session --reset-existing

# 清除会话后重新连接验证
node ./cli.mjs restart --reset-existing

# 关闭并重开 Remote Control 服务
node ./cli.mjs restart --reset-existing --restart-service
```

</details>

## 默认 XPI 安装

安装前核对任务授权。未签名 XPI 需要 Nightly 已配置 `xpinstall.signatures.required=false`；工具自身不修改该偏好。

| 返回状态 | 含义 |
| --- | --- |
| `active` | 目标版本已启用，且为非临时安装 |
| `restart-required` | 永久归档已接受，旧临时副本仍占位；正常重启后再次核验 |

工具保留扩展存储，不先卸载、不因失败回退临时安装。完整行为见[安装说明](docs/reference.md#默认-xpi-安装)。

安装已完成而后续清理失败时，CLI 仍返回 `ok:false`，同时保留 `data.installation`、已完成阶段及独立的错误码。先用 `verify` 核验，避免把清理失败当作未安装而重复写入。核验只读取扩展清单，不重新安装；连接准备仍遵守原有授权和服务归属。清单不能证明已安装文件的散列，结果会明确标注 `installedHashVerified:false`。

旧的远程连接确认框默认保留。只有当前任务已明确授权拒绝该旧请求时，才对 `run`、`install` 或 `start` 添加 `--deny-pending-consent`：拒绝一个已匹配的旧确认框后再建立本次连接，不批准旧请求、不记住授权、不重置共享调试会话。完整边界见[使用参考](docs/reference.md#后台与授权范围)。

## Agent skill

将客户端的 skill 入口联接到仓库中的唯一源目录。以 Codex 为例，在仓库根目录执行；目标已存在时先核对并备份：

```powershell
$skillSource = (Resolve-Path './skills/firefox-nightly-automation').Path
$skillTarget = Join-Path $env:USERPROFILE '.codex/skills/firefox-nightly-automation'
New-Item -ItemType Junction -Path $skillTarget -Target $skillSource
```

刷新客户端技能列表后，通过 `$firefox-nightly-automation` 调用。[Skill 规范](skills/firefox-nightly-automation/SKILL.md) · [Skillshare 说明](docs/reference.md#skillshare)

## 后台行为

默认直接开启 Remote Control，允许开启服务的原生控件操作引起目标主窗口激活，无需另行确认。本次连接对应的原生确认框也默认自动批准。最小化不再阻断连接、DOM 操作或页面截图；已开服务不恢复窗口，服务未开时只在限定的启动准备中临时恢复目标并还原原最小化状态。原生控件不可用仍返回具体失败。当前任务明确禁止原生准备激活时，以该要求为准。流程和实测边界见[最小化窗口](docs/minimized-windows.md)；业务操作仍以当前任务授权为准。

连接前自动取得稳定基线；标签切换、UIA 控件 ID 重建和用户复制内容仅观察，不单独中止连接或任务。这同样适用于服务准备、原生确认收尾及工作窗口。锁定后的窗口身份、真实几何或未授权焦点变化仍会阻止操作，失败原因写入 `background.lastFailure.reasons`；原始标签差异不改写。JSON 字段与边界见[使用参考](docs/reference.md#连接前稳定性检查)，报告保存在已忽略的 `.local/runs/`。

本次 Allow 暂未启用时，在同一次连接的期限内等待；原生调用状态见[控件诊断](docs/reference.md#原生控件诊断)。创建专用后台窗口、核验页面就绪、输入与截图时使用[后台验收流程](docs/background-acceptance.md)。

## 开发与许可

`npm test` 运行 Node 离线测试；安装 Python 依赖后，`npm run test:python` 运行会话重置 fixture。[验证记录](VALIDATION.md)区分离线测试与历史浏览器实测。

采用 [MIT](LICENSE) 许可证。Puppeteer Core、ws 和 Mozilla Marionette Driver 保留各自的 Apache-2.0、MIT、MPL-2.0 许可证。
