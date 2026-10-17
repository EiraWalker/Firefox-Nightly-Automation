# Firefox Nightly automation

AI Agent 可调用的 Windows 本地工具，用于已有 Firefox Nightly 的 Remote Control。默认连接 `C:\Program Files\Firefox Nightly\firefox.exe` 和 `ws://127.0.0.1:9222/session`。本次连接的原生确认框默认允许激活并自动点击 Allow，无需参数。主窗口和 Remote Control 面板保持严格后台；最小化或后台控件不可用时报告失败。

## 安装

在自己选择的目录克隆仓库，然后进入仓库根目录执行下列命令：

```powershell
git clone https://github.com/EiraWalker/Firefox-Nightly-Automation.git
Set-Location Firefox-Nightly-Automation
```

需要 Windows、已有 Firefox Nightly，以及下方列出的运行环境。本工具不会启动替代浏览器。

## 调用

需要 Node.js 22.12+、PowerShell 7 和依赖。Node 依赖安装：`npm ci --ignore-scripts --cache .local/npm-cache`。会话重置还使用本目录隔离的 Python 环境：`uv venv .venv --python 3.12`，随后 `uv pip sync requirements.txt --python .venv/Scripts/python.exe --require-hashes`；不修改全局 Python。

```powershell
node ./cli.mjs status
node ./cli.mjs start
node ./cli.mjs stop
node ./cli.mjs restart --reset-existing
node ./cli.mjs restart --reset-existing --restart-service
node ./cli.mjs reset-session --reset-existing
node ./cli.mjs run --task './examples/browser-status.mjs'
node ./cli.mjs install --xpi 'C:\packages\example.xpi'
```

- `status`：只读状态、端口所属进程、原生工具栏状态及本工具的服务归属。不会连接、点击或修改浏览器。
- `start`：需要时通过原生 Remote Control 面板后台开启，自动批准本次原生确认框，实际 BiDi 握手后断开客户端，保留服务供后续任务使用。
- `stop`：只关闭本工具先前开启且监听代次仍匹配的服务。预先开启的服务返回 `reason: not-owned` 并保留。停止前获取自己的独占连接；其他客户端占用时失败。
- `reset-session --reset-existing`：用户明确授权重置时，通过 Mozilla 官方 Marionette 传输执行 DeleteSession，清除当前共享的调试会话；保留服务、浏览器进程和窗口。当前无会话时返回 sessionAlreadyClear=true，不伪造删除。只接受目标 Nightly 的本机 2828 监听；不打开原生面板。
- `restart --reset-existing`：重置当前调试会话，然后重新连接验证。服务已开启时使用上述协议重置，返回 mode=session-reset/serviceRestarted=false。加 `--restart-service` 则通过原生面板关闭并重开服务，返回 mode=service-restart；两者都保留浏览器进程。重置成功但后续失败时，错误结果的 completedStages 记录完成阶段。只能在用户明确要求重置时调用，缺少 reset 标志立即报错。
- `run --task`：自动准备服务、批准自己的连接、执行模块、清理。仅关闭本次 run 新开启的服务，保留预先开启或先前 start 开启的服务。任务结束断开自己的客户端。
- `install --xpi`：默认扩展安装入口。先读取 XPI 清单、固定 ID、版本和 SHA256，再建立自己的连接并请求永久安装；结束后断开并按同样规则保留或关闭服务。

多窗口时可传 `--hwnd 0x12345`，必须来自本次 `status`/窗口发现结果。端口或安装路径不同可传 `--port 9222 --executable 'C:\Program Files\Firefox Nightly\firefox.exe'`。缺参数或不明确目标返回错误。

任务模块默认导出 `async function(browser)`，使用 Puppeteer 的公开 API。只操作任务授权的页面；不要调用 `browser.close()`、切换可见标签、操作 OS 键鼠或打印页面正文/凭据。示例仅返回 browser version 和连接状态。模块运行有正常的本机代码执行权限，工具不是任意代码沙箱。

## 默认 XPI 安装

安装业务需要用户授权；本项目的默认方式是上述 `install --xpi`，不再通过 Puppeteer `browser.installExtension()` 临时加载目录。开发者只有明确需要临时测试时才使用临时安装。

Nightly 安装未签名包的前提是用户已将 `xpinstall.signatures.required` 设置为 `false`。工具不修改此设置，也不跳过 Firefox 本身的包校验。Firefox Release/Beta 仍须使用 Mozilla 签名包。

工作流使用 [Mozilla 的 BiDi 扩展接口](https://firefox-source-docs.mozilla.org/remote/webdriver-bidi/Extensions.html)：`webExtension.install` 的 `archivePath` 和 `moz:permanent=true`，随后通过 `webExtension.moz:listExtensions` 核对目标 ID、版本、`isActive=true`、`temporarilyInstalled=false`。成功激活返回 `data.installation.status=active`，并保留安装收据。相同 ID 走正常更新；同版本也提交，避免跳过重新构建的包。工具不会先卸载、清空存储或失败后改用临时加载。

首次从临时安装迁移时，Firefox 可能先把永久包写入 `app-profile`，仍由优先级更高的临时副本占位。此时返回 `status=restart-required`、`permanent=true` 和 `visibleAddon`，表示永久归档安装成功，**尚未确认永久副本启用**；不提供误导性的 active 收据。正常退出再启动 Nightly 后重新执行安装即可完成核验。工具不会自行重启浏览器，也不会卸载临时副本：Firefox 的 `onUninstalled` 会清理设置、授权和存储。原副本禁用时，正式副本可能继承禁用状态；重启后的安装重试会走 Firefox 正常重新安装/启用路径。

失败报告的 `completedStages` 在 Firefox 接受归档后记录 `addon-archive-installed`，确认正式副本启用后才增加 `addon-installed`。后续桌面检查或断开失败不撤销这些事实；先查看收据和当前状态，再决定是否重试。

## 后台与授权范围

原生控件通过 UI Automation InvokePattern 调用。主窗口和 Remote Control 面板不主动激活，不恢复最小化窗口；最小化或 offscreen 开关返回 `F_BACKGROUND_CONTROL_UNAVAILABLE`。本次已匹配确认框的 Allow 通过原生 Invoke 调用，接受该控件自身引起的确认框激活及焦点回返。没有 SetForegroundWindow、ShowWindow、宽泛窗口激活开关或主窗口恢复路径。不使用 OS 键鼠、剪贴板写入或浏览器进程重启。三个对象的定义见 [GLOSSARY](GLOSSARY.md)。

当前 Nightly 工具栏 Invoke 会激活所属主窗口，所以服务面板动作只在目标主窗口已经处于前台时尝试；其他应用处于前台则先返回后台不可用，不重复已知会抢焦点的操作。已经开启的服务可以直接进行协议重置和连接，本次确认框的默认 Allow 不受这项面板限制影响。

连接确认只在本工具持有操作锁并创建一条连接时检查。拒绝预先存在或多个授权框，核对 Nightly 进程、原生 `MozillaDialogClass`/`commonDialogWindow`、完整固定说明、Allow/Deny 与记住决定复选框。支持桌面顶层和浏览器窗口直接子节点中的原生弹窗，不搜索网页。确认归属及原生结构后，默认调用原生 Allow，接受该动作引起的确认框激活及焦点回返，核对弹窗关闭及真实握手。复选框保持未勾选，不更改 Firefox 的授权偏好。

明确授权 reset 时可以用 WM_CLOSE 取消目标 Nightly 中一个已匹配的原生远程连接确认框，再清理共享会话。确认框关闭引起的焦点回返归入确认框处理区间；结构或归属不明确时拒绝。普通任务不能借此取消其他客户端的请求。

WinEventHook 连续记录前台切换。只有已匹配确认框的处理区间允许焦点进入该确认框，以及关闭后回到对应浏览器或原先前台。其他窗口、其他确认框、处理之前或之后的焦点变化均不豁免；后台面板调用仍受严格检查。浏览器窗口位置/最小化状态、窗口集合、选中标签 runtime ID 和剪贴板序号始终必须保持稳定，否则返回 `F_DESKTOP_CHANGED`。

`background.foregroundStable` 保留完整原始观察，不会因确认框例外变为 true；`foregroundWithinConsentPolicy` 表示焦点变化符合上述边界，`consentFocusActive` 标识确认框处理区间是否仍开启。报告固定标明 consentActivationDefault=true、mainWindowActivationAllowed=false。只读 status 不激活窗口；当前实测见 VALIDATION.md。

当前原生适配器只接受已核对的 Nightly 160.0a1 英文控件结构。其他结构、语言或升级后无法识别时返回明确错误，不改用坐标点击。Nightly 原生面板的初始配置 `remote.experimental.dynamicstart.enabled=true` 属于已有浏览器准备；本工具不改 profile 或 about:config。

## 输出和失败处理

stdout 输出 JSON，成功 `ok:true`、退出码 0；失败 `ok:false`、退出码 1。`handshake:true` 证明实际 Firefox BiDi 会话成功；`consent.invoked:true && consent.closed:true` 证明本次授权框已调用并关闭，不能仅凭端口或 Invoke 请求判断成功。

运行报告与请求阶段轨迹保存到 `.local/runs/`，不保存任务返回的数据。服务归属绑定浏览器 PID、启动时间、可执行路径和 TCP 监听创建时间，手动关闭重开会使旧归属失效。操作锁覆盖整个调用，避免两个本工具 Agent 同时批准连接。

常见错误：

| 错误 | 含义 |
| --- | --- |
| F_BACKGROUND_CONTROL_UNAVAILABLE | 开关或按钮最小化、不可见或不支持后台 Invoke |
| F_BACKGROUND_PANEL_UNAVAILABLE | 无法在后台取得原生面板 |
| F_DESKTOP_CHANGED | 确认框例外之外的焦点变化，或浏览器窗口/选中标签/剪贴板变化 |
| F_CONSENT_ALREADY_PRESENT / F_CONSENT_AMBIGUOUS | 授权框归属不明确，不点击 |
| F_CONSENT_SHAPE_UNKNOWN | 弹窗不是受支持的原生结构 |
| F_SESSION_BUSY | Firefox 已有其他调试会话，不接管 |
| F_ENDPOINT_UNSAFE | 端口不属于目标 Nightly 或不是本机监听 |
| F_OPERATION_BUSY | 另一个本工具任务持有操作锁 |
| F_XPI_REQUIRED / F_XPI_INVALID / F_XPI_ID_REQUIRED | 缺少 XPI、包/清单不合法或缺少固定扩展 ID；连接浏览器前拒绝 |
| F_ADDON_SIGNATURE_REQUIRED | Firefox 拒绝签名校验；不更改偏好或回退临时安装 |
| F_ADDON_INVENTORY_UNAVAILABLE / F_ADDON_ID_MISMATCH | 无法核验清单或返回了不同 ID；不冒充安装通过 |
| F_ADDON_INSTALL_FAILED / F_ADDON_INSTALL_NOT_CONFIRMED | 安装请求失败或正式副本未确认启用；检查已完成阶段 |
| F_TEMPORARY_ADDON_CONFLICT | 非预期临时副本出现在核验结果中；不自动卸载 |

失败后先看 `nativeTrace` 与当前 `status`，不盲目重放点击。连接失败会关闭自有传输，并在能确定弹窗归属且后台检查通过时取消自有授权请求。无法确认的弹窗保留，不能点击其他请求。若进程被外部终止留下 `.local/operation.lock`，先核对记录的 PID 已退出再删除这一个锁文件；正常退出自动释放。不能因错误自动清空用户 profile 或关闭其他会话。

## 代码职责

`src/native.ps1` 封装原生选择器和动作；`src/desktop-guard.cs` 观察 Windows 状态并定向取消原生连接框；`src/consent-focus.cs` 核对确认框焦点例外及前后边界；`src/connection.mjs` 管理 Puppeteer 连接和失败传输；`src/reset.mjs`/`src/reset_session.py` 用锁定的 Mozilla Marionette Driver 3.7.1 实现明确授权的共享会话重置；`src/automation.mjs` 管理开启、任务执行和归属清理；`src/state.mjs` 维护私有归属/操作锁；`cli.mjs` 提供 JSON 调用入口。

原生确认框期间若桌面枚举暂时缺少已核对的浏览器窗口，适配器按保存的 HWND 和进程身份重新读取原生 UIA 元素，仍核对工具栏、窗口位置和标签，不执行窗口激活。方法参考 [Microsoft AutomationElement.FromHandle](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.automationelement.fromhandle)。

协议由锁定的 Puppeteer Core 25.13.0 实现，ws 实现 Puppeteer 的公开 ConnectionTransport 接口。Firefox 断开 socket 不会自动销毁会话；若 Puppeteer 在 session.new 成功后初始化失败，传输仅在本工具原 socket 上发送标准 session.end，避免遗留自己的会话。不通过新 socket 接管或清除其他会话。原生控件来自 Mozilla 安装包的实际源码/本机 UIA 检查，未复制浏览器实现。

AI Agent 入口见 [skill](skills/firefox-nightly-automation/SKILL.md)。

## 安装 Agent skill

唯一 skill 源在仓库的 `skills/firefox-nightly-automation`。将客户端的同名 skill 目录联接到该目录，不复制源码或在客户端目录另行维护版本。目录联接支持同机不同 NTFS 卷。

以 Codex 为例，在仓库根目录执行；目标已经存在时先核对并备份，不能直接覆盖：

```powershell
$skillSource = (Resolve-Path './skills/firefox-nightly-automation').Path
$skillTarget = Join-Path $env:USERPROFILE '.codex/skills/firefox-nightly-automation'
New-Item -ItemType Junction -Path $skillTarget -Target $skillSource
```

使用 Skillshare 时，其源目录中的同名位置可保留联接作为本机入口；本 skill 由独立仓库 Git 维护。部分版本不遍历源目录中的联接，客户端应直接联接原始 skill，不通过 collect/pull 复制维护。全局同步前检查 dry-run，确认不会覆盖客户端入口。通过联接访问时，skill 按真实路径定位工具根目录；刷新客户端技能列表后生效。

## 许可证

本项目采用 [MIT](LICENSE)。安装依赖保留各自许可证：Puppeteer Core 为 Apache-2.0，ws 为 MIT，Mozilla Marionette Driver 为 MPL-2.0；依赖源码和运行环境不随本仓库分发。
