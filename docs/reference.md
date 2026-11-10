# 使用参考

[返回首页](../README.md)

## 默认启动权限

启动 Nightly 默认使用 `scripts/start-nightly.ps1`，为 Firefox 子进程设置 `MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1`。本工具称其为 Agent full access；这是 Firefox Remote Agent 的 system access，用于已授权的浏览器内部页任务，不改变 Windows 账户权限或页面业务操作的授权范围。[Mozilla 定义](https://firefox-source-docs.mozilla.org/remote/Security.html#system-access)。

```powershell
pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '<工具根目录>/scripts/start-nightly.ps1'
```

启动器按 executable 和 profile 串行协调 GUI 启动，等待同一安装目录的更新器退出，并以浏览器窗口的消息响应确认就绪。启动尚未完成时再次点击会等待并复用已有实例；不会再制造一个“Firefox 已运行但无响应”的启动请求。超时保留原进程和数据，不自动杀进程、清缓存或重启。私有结果写入工具目录的 `.local/launch/`，不记录页面内容或命令行参数。

已授权自动化任务发现原进程和窗口均已退出、没有可复用目标时，默认通过同一启动器新建 Nightly 空白窗口，无需再次申请启动许可。重新发现 PID/创建时间、HWND 和服务代次；旧 HWND 不继承到新进程。已有但无响应的进程仍按原保护处理，不借此重启或另开替代实例。

从 Git Bash 调用、且 `-Arguments` 的值以 `-` 开头时，使用 `-Command` 在 PowerShell 语言层传值，避免 `-File` 将该值误判为新参数：

```bash
pwsh.exe -NoProfile -NonInteractive -Command '& "<工具根目录>/scripts/start-nightly.ps1" -Arguments "-new-window about:blank" -NoActivate -PassThru'
```

新进程以及最近两分钟内的系统登录自启进程会附带一个后台启动观察器。只有同时满足窗口持续无响应、本次启动刚生成的 Firefox 主线程卡顿记录包含 `StartupCache::GetBuffer`、线程处于 Windows 后台 I/O 模式时，才尝试一次最多十秒的 I/O 恢复：将这些线程的 I/O 优先级临时恢复到普通级别。未结束后台模式的无关线程随后恢复原级别；不改 CPU/内存优先级或浏览器偏好。旧记录、其他卡顿、旧进程和权限不足均不会触发宽泛恢复。每次启动收据与每个进程的 `.health.json` 分别保留，已完成的恢复不会被重复观察器覆盖。

恢复前会将匹配的 Firefox 卡顿记录保存在健康报告旁的 `.bhr.bin`，以便原始记录被 Firefox 移除后仍能核查。报告中的 `recovered` 表示调整后窗口恢复响应，不单独证明卡顿的底层原因已消除。

可传 `-ExecutablePath '<firefox.exe>'`、`-Arguments '<完整 Windows 命令行参数>'`、`-ProfilePath '<已有 profile 目录>'`、`-StartupTimeoutSeconds 120` 和 `-NoActivate`。`-ProfilePath` 用于需要独立协调的显式 GUI profile，不能同时在 `-Arguments` 中指定 profile；原有 raw `-profile` / `-P` / `-no-remote` 和 headless、help、version、backgroundtask 命令保持直接转交行为。`-NoActivate` 适合后台检查，不恢复或激活复用的窗口。

`-PassThru` 输出进程 ID、路径、`mode=started/reused`、`ready` 和 `requestedSystemAccess`。复用但没有启动新请求时，`requestedSystemAccess=false`；权限保持原进程的状态。新启动时为子进程设置权限变量，收据仍不等于内部页验收。完整权限验收需在新进程中实际访问目标内部页。

日常启动使用无控制台入口 `scripts/start-nightly.vbs`，由 Windows Script Host 在创建 PowerShell 时隐藏窗口，避免直接运行 `pwsh.exe -WindowStyle Hidden` 时可能短暂闪出黑框。入口通过本机 PowerShell 7 应用执行别名运行原有 `start-nightly.ps1`，启动协调逻辑保持集中在 PowerShell 脚本中。命令行自动化仍可直接使用上面的 PowerShell 接口。

任务栏快捷方式目标设为 `%WINDIR%\System32\wscript.exe`，参数设为 `//B //Nologo "<工具根目录>\scripts\start-nightly.vbs"`，保留 Nightly 图标与 AppUserModelID。修改前备份原始 `.lnk`。该入口仅接受 `-NoActivate` 和 `-OsAutostart`；其他自定义参数使用 PowerShell 接口。

已启用 Windows 登录自启的安装也应使用同一个入口，在上述参数后追加 `-OsAutostart`，入口会向 PowerShell 转交 `-NoActivate -Arguments "-os-autostart"`。先备份对应 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 Nightly 值，再替换这一条命令；不要额外添加第二个自启项。Firefox 原生登录开关按该值是否存在判断启用状态，保留值名后仍可从 Firefox 设置中关闭。如果用户以后从 Firefox 设置重新启用自启，它会重写为原生命令，需要重新接回本启动器。

环境变量仅作用于新启动的 Firefox 子进程，不写入注册表或当前 PowerShell 环境。启动器不终止现有浏览器；若已有实例，Firefox 可能将请求转交给它，此时不会补上启动权限。正常退出后再从此入口打开，才能使新进程获得权限。`reset-session`、`restart` 和 Remote Control 服务开关都不改变已有浏览器的启动环境。

## 会话与命令

- `status`：只读状态、端口所属进程、原生工具栏状态及本工具的服务归属。不会连接、点击或修改浏览器。
- `start`：需要时通过原生 Remote Control 面板后台开启，自动批准本次原生确认框，实际 BiDi 握手后断开客户端，保留服务供后续任务使用。
- `stop`：只关闭本工具先前开启且监听代次仍匹配的服务。预先开启的服务返回 `reason: not-owned` 并保留。停止前获取自己的独占连接；其他客户端占用时失败。
- `reset-session --reset-existing`：用户明确授权重置时，通过 Mozilla 官方 Marionette 传输执行 DeleteSession，清除当前共享的调试会话；保留服务、浏览器进程和窗口。当前无会话时返回 sessionAlreadyClear=true，不伪造删除。只接受目标 Nightly 的本机 2828 监听；不打开原生面板。
- `restart --reset-existing`：重置当前调试会话，然后重新连接验证，返回 mode=session-reset/serviceRestarted=false。加 `--restart-service` 则先重置会话、取得自己的独占连接，校验同一进程和服务代次后优先通过协议停止；能力不支持时才保留受守卫的原生路径。原生读回确认关闭后，再走正常启动准备并验证新连接，返回 mode=service-restart；两者都保留浏览器进程。协议停止发出后不重发或回退；明确授权的重启不伪造借用服务的持久归属。重置成功但后续失败时，错误结果的 completedStages 记录完成阶段。普通页面任务仍需要明确的重置授权；维护冷启动起停按默认维护授权执行，缺少 reset 标志立即报错。
- `run --task`：自动准备服务、批准自己的连接，在独立后台工作窗口执行模块并清理。用户其他窗口的正常活动不触发工作窗口守卫。仅关闭本次 run 新开启的服务，保留预先开启或先前 start 开启的服务。任务结束关闭自己的工作窗口并断开自己的客户端。
- `install --xpi`：默认扩展安装入口。先读取 XPI 清单、固定 ID、版本和 SHA256，再建立自己的连接并请求永久安装；结束后断开并按同样规则保留或关闭服务。
- `verify --xpi '<包>'`：读取本地包的 ID、版本和 SHA256，对照浏览器清单核验版本正确、启用且非临时；不发送安装或卸载请求。`verify --id '<扩展 ID>'` 只核验指定 ID 的正式副本。两种目标互斥。结果中的 `installedHashVerified=false` 表示清单不包含已安装文件的散列，不把本地包散列冒充为安装文件的散列。只读限于扩展业务；连接准备仍会按原规则处理服务和本次确认框。

多窗口时可传 `--hwnd 0x12345`，必须来自本次 `status`/窗口发现结果。端口或安装路径不同可传 `--port 9222 --executable 'C:\Program Files\Firefox Nightly\firefox.exe'`。缺参数或不明确目标返回错误。

任务模块默认导出 `async function(browser, workspace)`，使用 `workspace.page` 和任务范围的 browser-like 接口；不直接暴露全局 Puppeteer Browser/连接。该接口不承诺全 Puppeteer 兼容。归属、生命周期、用户并行活动及共享存储边界见[独立工作窗口](task-workspace.md)。模块运行有正常的本机代码执行权限，工具不是任意代码沙箱。

## 默认 XPI 安装

安装业务需要用户授权；本项目的默认方式是上述 `install --xpi`，不再通过 Puppeteer `browser.installExtension()` 临时加载目录。开发者只有明确需要临时测试时才使用临时安装。

Nightly 安装未签名包的前提是用户已将 `xpinstall.signatures.required` 设置为 `false`。工具不修改此设置，也不跳过 Firefox 本身的包校验。Firefox Release/Beta 仍须使用 Mozilla 签名包。

工作流使用 [Mozilla 的 BiDi 扩展接口](https://firefox-source-docs.mozilla.org/remote/webdriver-bidi/Extensions.html)：`webExtension.install` 的 `archivePath` 和 `moz:permanent=true`，随后通过 `webExtension.moz:listExtensions` 核对目标 ID、版本、`isActive=true`、`temporarilyInstalled=false`。成功激活返回 `data.installation.status=active`，并保留安装收据。相同 ID 走正常更新；同版本也提交，避免跳过重新构建的包。工具不会先卸载、清空存储或失败后改用临时加载。

首次从临时安装迁移时，Firefox 可能先把永久包写入 `app-profile`，仍由优先级更高的临时副本占位。此时返回 `status=restart-required`、`permanent=true` 和 `visibleAddon`，表示永久归档安装成功，**尚未确认永久副本启用**；不提供误导性的 active 收据。正常退出再启动 Nightly 后重新执行安装即可完成核验。工具不会自行重启浏览器，也不会卸载临时副本：Firefox 的 `onUninstalled` 会清理设置、授权和存储。原副本禁用时，正式副本可能继承禁用状态；重启后的安装重试会走 Firefox 正常重新安装/启用路径。

失败报告的 `completedStages` 在 Firefox 接受归档后记录 `addon-archive-installed`，确认正式副本启用后才增加 `addon-installed`。后续桌面检查或断开失败不撤销这些事实；先查看收据和当前状态，再决定是否重试。

原本禁用的同版本永久副本有一个特殊边界：第一次请求可能只重新启用旧文件，此时尚不记录归档安装。观察到重新启用后再提交归档，第二次接受才记录 `archiveInstalled=true` 和 `addon-archive-installed`；第二次失败、超时或一直未启用均不虚报该阶段。后续激活确认失败仍保留已经接受归档的事实。`installedHashVerified=false` 继续如实表示协议清单不能证明已安装文件散列。

## 后台与授权范围

原生控件通过 UI Automation InvokePattern 调用。默认直接开启 Remote Control，接受开启步骤中原生控件引起的目标主窗口激活，无需另行确认。本次已匹配确认框的 Allow 也通过原生 Invoke 调用，接受确认框激活及焦点回返。最小化本身不再阻断连接、DOM 或页面截图；服务未开且原生面板需要显示时，使用限定的启动准备租约并还原原最小化状态。原生 offscreen、禁用或缺少 InvokePattern 仍按实际控件状态失败。流程与实测边界见[最小化窗口](minimized-windows.md)。不使用 OS 键鼠、剪贴板写入或浏览器进程重启。三个对象的定义见 [GLOSSARY](../GLOSSARY.md)。

开启服务时，工具先核对进程身份、目标 HWND 和原生工具栏状态，再记录限定于该目标窗口的焦点例外。已最小化的目标只在此区间临时恢复，结束时以实际读回确认原状；被遮挡的正常原生窗口可使用 UIA SetFocus 准备控制，随后重新取得并核对 HWND 和控件。两者都不绕过 offscreen、禁用或名称检查。完成或失败时关闭例外并继续审计全部事件。已经开启的服务直接连接，不恢复最小化窗口。若当前任务明确禁止原生准备激活，调用方只复用已开服务，不调用会自动开启服务的命令，并报告无法满足的前置条件。

关闭自有同代服务时，持有自己的独占 BiDi 会话直到停止请求发出。当前进程已允许 system access、会话支持 Chrome scope 时，先在确认为 `chrome://browser/content/browser.xhtml` 的内部上下文中检查动态服务和活动会话，再通过本机 Mozilla 的 `RemoteControlServers.stop()` 关闭。发出前再次执行桌面守卫；不设置偏好、不补充启动权限、不访问网页正文。发出后只释放这个自有客户端一次，再独立读取原生工具栏和端口，避免 Firefox 等待同一个客户端而拖住关闭；外层 finally 复用同一释放结果，不重发 disconnect/session.end。socket 消失本身不等于成功，也不触发第二次关闭或原生回退。只有工具栏可读且关闭、监听消失才清除归属。

只有发出关闭请求前能力探测不支持，才保留原生路径：限定于目标原生 `notifications-toolbar` 中唯一可用的 `Turn off remote control` 或 `Disconnect` 按钮，并在调用边界重新核对名称。当前 Nightly 的连接态 `Disconnect` 与待连接态的关闭按钮调用同一个服务停止方法，并非仅关闭 socket；仍必须读回两个关闭信号。没有该通知条且主窗口本来就在前台时，才保留面板关闭路径。原生动作若导致焦点或其他受保护状态变化，保留失败，不放宽守卫，不把 Invoke 已发出冒充清理完成。

连接确认只在本工具持有操作锁并创建一条连接时检查。拒绝预先存在或多个授权框，核对 Nightly 进程、原生 `MozillaDialogClass`/`commonDialogWindow`、完整固定说明、Allow/Deny 与记住决定复选框。支持桌面顶层和浏览器窗口直接子节点中的原生弹窗，不搜索网页。确认归属及原生结构后，默认调用原生 Allow，接受该动作引起的确认框激活及焦点回返，核对弹窗关闭及真实握手。复选框保持未勾选，不更改 Firefox 的授权偏好。

明确授权 reset 时可以用 WM_CLOSE 取消目标 Nightly 中一个已匹配的原生远程连接确认框，再清理共享会话。确认框关闭引起的焦点回返归入确认框处理区间；结构或归属不明确时拒绝。普通任务不能借此取消其他客户端的请求。

旧待授权请求的拒绝与共享会话重置分开授权。仅当当前任务已授权清理那个旧确认框时，对 `run`、`install` 或 `start` 传 `--deny-pending-consent`。工具在本次连接前只执行一次拒绝：没有旧框返回 `pendingConsent.closed=false`；单个原生框完整匹配且记住决定未勾选时才关闭，并读回确实消失。多个、结构未知、已勾选、范围变化或桌面守卫失败均停止，不批准旧连接，不删除现有调试会话，不重放业务任务。默认不带该参数的行为仍是 `F_CONSENT_ALREADY_PRESENT`。

`run` 的工作窗口模式按[独立工作窗口](task-workspace.md)判断：用户其他窗口活动只观察，任务窗口的身份和未授权激活仍检查。以下全窗口稳定性要求适用于其他命令的旧严格模式；原始全局观察在两种模式下都保留。

WinEventHook 连续记录前台切换。开启服务区间仅允许已核对目标主窗口；已匹配确认框区间允许该确认框及其对应浏览器。旧严格模式下，锁定后其他 Nightly 窗口、其他确认框、区间之外的浏览器焦点变化均不豁免。用户在其他应用中的前台切换保留在原始观察中，不阻止后台连接。

### 连接前稳定性检查

首次原生控件动作或创建连接前，适配器最多读取四次窗口快照，相邻采样至少间隔 50ms。取得连续一致的窗口集合和正常窗口几何后，锁定检查基线。标签切换仅观察，持续切换也不单独耗尽准备采样；仅最小化/还原不改变合法正常几何时可继续。此前用户已完成的其他窗口调整可以作为准备状态。锁定后不再更新基线，不重新执行连接、点击或页面任务。受保护状态持续变化返回 `F_DESKTOP_UNSTABLE`，保留准备阶段的失败原因。

选中标签优先使用 tab strip 内唯一的 AutomationId；缺失或重复时使用选中位置。任务模块仍须按实际完整 URL/标题复核业务目标，不能把位置当作页面身份。UIA Runtime ID 仅用于诊断控件重建，不再单独判定用户切换标签；其语义见 [Microsoft GetRuntimeId](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.automationelement.getruntimeid)。窗口字段逐项比较，不依赖 JSON 对象字段或枚举顺序。

`tabSelectionPolicy=observe-only` 对严格模式、工作窗口、服务启动准备及原生确认租约一致生效。比较器的 `windowsWithinControlPolicy` 只放宽标签选择，不替代窗口集合、合法几何和观察可用性检查；租约仍单独验证 PID、创建代次、HWND 生命周期标记和授权区间。标签切换不使任务改用当前选中页，也不授权额外页面；BiDi context/window 归属及业务目标核验保持不变。

| 字段 | 含义 |
| --- | --- |
| `windowsStable` / `selectedTabsStable` | 相对已锁定基线的原始窗口与标签状态；纯切页可为 false，不单独表示失败 |
| `scopedWindowsStable` | 当前严格/工作窗口作用域的窗口策略判定；不以标签选择是否相同作为阻断条件 |
| `tabSelectionPolicy` | 固定 observe-only；选中标签及 provider 原始诊断继续如实报告 |
| `windowGeometryStable` / `minimizedStateStable` | 原始外框和最小化状态是否相同；可能为 false 而正常几何仍有效 |
| `canonicalGeometryStable` | 正常位置及还原模式是否一致；最小化变化本身不是失败 |
| `serviceWindowPreparation` | 启动准备临时恢复、状态读回和收尾的限定诊断，不单独证明握手成功 |
| `workspaceGeometry` / `lastFailure.workspaceGeometry` | 仅已登记 HWND 的预期/实际几何；后者保留失败时快照，避免把全局字段误读为 owned 窗口变化 |
| `initialWindowsStable` | 相对进程初始化时快照的原始观察，可能因准备阶段合法变动为 false |
| `tabProviderIdentityStable` | UIA Runtime ID 是否一致，仅诊断 |
| `clipboardStable` / `clipboardPolicy` | 原始剪贴板序号是否一致；策略为 observe-only，不因用户复制而失败 |
| `desktopChanges` / `scopedDesktopChanges` | 最新全局/工作窗口快照的变化项；保留仅观察的 tab-selection |
| `lastFailure.reasons` | 触发失败那一刻的阻断原因，不含仅观察的 tab-selection，不会被后续状态读取覆盖 |
| `preflightRebases` / `guardLocked` | 是否采纳过准备阶段变化，以及基线是否已锁定 |

严格模式下，锁定后的窗口增减、真实位置/还原模式变化及未授权浏览器焦点变化仍返回 `F_DESKTOP_CHANGED`。常见原因为 `window-set`、`window-position`、`browser-focus`；元数据缺失时保留保守的 `window-minimized` 比较，非法元数据报告 `window-placement-invalid`。纯标签切换仅记录 `tab-selection`；同时存在其他违规时仍拒绝，并保留原始标签诊断。观察不可用仍拒绝，不把缺失观测伪装成稳定。不收集用户标题、URL、正文或剪贴板内容。工作窗口模式使用已登记对象的独立判定，不把上述全局差异一概视为失败。

`background.foregroundStable` 保留完整原始观察；`foregroundWithinControlPolicy` 汇总开启服务和确认框两种例外，`foregroundWithinConsentPolicy` 保留仅确认框的检查，因此开启服务激活窗口后，前者可为 true 而后者为 false。2026-10-17 起新增 `browserForegroundWithinControlPolicy`，按目标 Nightly 的窗口及原始事件索引判断这两种例外，作为前台检查的执行依据；用户切换其他应用只记录，不再导致连接前失败。原始字段仍可能为 false，不能据此宣称整段桌面前台不变。`consentFocusActive`、`serviceStartFocusActive` 分别表示两种区间是否仍开启，`mainWindowActivationAllowed` 仅在开启服务区间为 true。报告标明 consentActivationDefault=true、serviceStartActivationDefault=true。只读 status 不激活窗口；当前实测见 [验证记录](../VALIDATION.md)。

当前原生适配器只接受已核对的 Nightly 160.0a1 英文控件结构。其他结构、语言或升级后无法识别时返回明确错误，不改用坐标点击。Nightly 原生面板的初始配置 `remote.experimental.dynamicstart.enabled=true` 属于已有浏览器准备；本工具不改 profile 或 about:config。

## 输出和失败处理

后台专用窗口、导航超时后的就绪核验、可信输入与图像证据见[后台页面验收](background-acceptance.md)。

stdout 输出 JSON，成功 `ok:true`、退出码 0；失败 `ok:false`、退出码 1。`handshake:true` 证明实际 Firefox BiDi 会话成功；`consent.invoked:true && consent.closed:true` 证明本次授权框已调用并关闭，不能仅凭端口或 Invoke 请求判断成功。

原生 worker 的只读初始化包含 PowerShell 编译和 UIA 首次发现，等待上限为 60 秒；超时是本次 worker 的终止性失败，后续诊断不再重复等待同一轮初始化。只读 `status` / `report` / `assert` 也使用固定 60 秒上限，容纳首次 CIM/端口查询；普通原生动作（包括关闭服务）保持 20 秒上限。开启服务的复合准备事务单独有 60 秒上限，覆盖临时还原、每次原生动作前的归属检查及 finally 的最小化读回。各期限固定且不自动重放；窗口状态未知、排队动作尚未观察到执行或原状未读回时，不能把超时报告成成功。

运行报告与请求阶段轨迹保存到 `.local/runs/`，不保存任务返回的数据。服务归属绑定浏览器 PID、启动时间、可执行路径和 TCP 监听创建时间，手动关闭重开会使旧归属失效。操作锁覆盖整个调用，避免两个本工具 Agent 同时批准连接。

业务已完成而后续桌面检查、断开或清理失败时，仍保留失败退出码与 `ok=false`，并返回已观察到的结果：安装/核验结果在 `data.installation`；通用任务结果在 `data.task`，仅返回调用者，不写入诊断文件。`taskError` 与 `cleanupError` 分别保留业务和后续失败码；两者同时发生时以清理错误作为顶层 `error`，不会抹掉业务错误。`completedStages` 是已完成事实，不代表整次运行通过。核对当前状态后再决定下一步，不自动重放已经产生副作用的任务。

多阶段清理失败还返回按发生顺序排列的 `cleanupErrors: [{stage, code}]`，保留工作窗口、服务、连接、原生进程及锁释放等实际失败，不用第一个错误掩盖后续失败。字段仅包含固定阶段名与脱敏错误码；顶层主错误优先级不变。

常见错误：

| 错误 | 含义 |
| --- | --- |
| F_BACKGROUND_CONTROL_UNAVAILABLE | 原生控件禁用、屏幕外或缺少 InvokePattern；已核对的本次 Allow 禁用时先在连接期限内等待 |
| F_CONNECTION_TIMEOUT | 同一次连接未在期限内完成；检查 Allow 是否一直等待启用及握手状态 |
| F_NATIVE_TIMEOUT | 原生 worker 初始化或原生请求超过有界期限；阶段不同，不据此重放已发动作 |
| F_BACKGROUND_PANEL_UNAVAILABLE | 无法在后台取得原生面板 |
| F_SERVICE_WINDOW_CHANGED | 启动准备中的目标代次、窗口生命周期或真实几何变化；纯标签切换不触发 |
| F_SERVICE_WINDOW_RESTORE_FAILED | 有界读回未确认恢复或重新最小化完成；检查 serviceWindowPreparation |
| F_DESKTOP_CHANGED | 锁定后受保护窗口或未授权浏览器焦点变化，具体见 lastFailure.reasons；纯标签切换不触发 |
| F_DESKTOP_UNSTABLE | 连接准备阶段未取得连续稳定快照，尚未执行原生动作 |
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
| F_VERIFY_TARGET_REQUIRED | `verify` 未指定 `--xpi` 或 `--id`；连接前拒绝 |
| F_ADDON_NOT_FOUND / F_ADDON_VERIFY_NOT_CONFIRMED | 指定扩展不存在，或版本、启用、非临时条件未满足；保留只读核验收据 |

失败后先看 `nativeTrace` 与当前 `status`，不盲目重放点击。连接失败会关闭自有传输，并在能确定弹窗归属且后台检查通过时取消自有授权请求。无法确认的弹窗保留，不能点击其他请求。若进程被外部终止留下 `.local/operation.lock`，先核对记录的 PID 已退出再删除这一个锁文件；正常退出自动释放。不能因错误自动清空用户 profile 或关闭其他会话。

### 原生控件诊断

检查 `background.lastControlState` 和 `lastInvocationIssued`：

| 字段 | 含义 |
| --- | --- |
| `action` | 本次检查的原生动作名 |
| `enabled` / `offscreen` | 调用前读取的控件启用与屏幕外状态 |
| `invokeAvailable` | 是否取得 InvokePattern；null 表示尚未查询 |
| `lastInvocationIssued` | 是否已向原生控件发出 Invoke；不代表确认框关闭或握手成功 |

仅对已核对进程、结构、完整说明及未勾选记住决定的本次 Allow，`enabled=false && offscreen=false` 返回 `waitingFor=allow-enabled`，由同一次连接继续轮询。状态在最终调用边界重新读取，覆盖发现后又禁用的竞争；等待共享同一次连接的固定期限（默认 45 秒，以容纳冷 UIA 观察），不会重新建连或滚动延长期限。其他原生控件禁用、任何控件屏幕外、缺少 InvokePattern 或确认范围变化仍失败。已发出的批准不重放。

连接成功期限从进入 `beginConsent` 前开始，传输建立、SDK 握手、最终 consent/version/桌面检查和正常结束都共享剩余预算。任何阶段超期，即使稍后完成也不返回成功。已排队的原生 RPC 不被遗弃；其有界完成和失败清理可以越过成功期限，但不会开启新一轮连接、重发动作或再次结束已经发出的 `endConsent`。自有断连失败用固定 `F_DISCONNECT_FAILED` 作为次级错误保留，不以 provider 私有文本覆盖原生主错误。

确认已调用且弹窗关闭后，等待 Puppeteer 初始化期间不再反复枚举原生 UIA；最终仍重新检查确认框、真实握手及原锁定桌面守卫。监听器和原始事件保持，不为等待握手重设基线。

历史收据缺少 lastControlState 时，不能仅凭 F_BACKGROUND_CONTROL_UNAVAILABLE 断言是窗口最小化；先区分原生控件、连接握手与页面导航失败阶段。最终报告保留原始失败，即使某个业务步骤已经成功。

## 代码职责

`src/native.ps1` 封装原生选择器和动作；`src/desktop-guard.cs` 观察 Windows 状态并定向取消原生连接框；`src/consent-focus.cs` 核对确认框焦点例外及前后边界；`src/connection.mjs` 管理 Puppeteer 连接和失败传输；`src/service-stop.mjs` 在已有授权的 Chrome scope 内探测并请求关闭自有服务，原生状态仍由调用方独立核验；`src/reset.mjs`/`src/reset_session.py` 用锁定的 Mozilla Marionette Driver 3.7.1 实现明确授权的共享会话重置；`src/automation.mjs` 管理开启、任务执行和归属清理；`src/state.mjs` 维护私有归属/操作锁；`cli.mjs` 提供 JSON 调用入口。

原生确认框期间若桌面枚举暂时缺少已核对的浏览器窗口，适配器按保存的 HWND 和进程身份重新读取原生 UIA 元素，仍核对工具栏、窗口位置和标签，不执行窗口激活。方法参考 [Microsoft AutomationElement.FromHandle](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.automationelement.fromhandle)。

协议由锁定的 Puppeteer Core 25.13.0 实现，ws 实现 Puppeteer 的公开 ConnectionTransport 接口。Firefox 断开 socket 不会自动销毁会话；若 Puppeteer 在 session.new 成功后初始化失败，传输仅在本工具原 socket 上发送标准 session.end，避免遗留自己的会话。不通过新 socket 接管或清除其他会话。原生控件来自 Mozilla 安装包的实际源码/本机 UIA 检查，未复制浏览器实现。

默认传输只从 Puppeteer 的广域启动模块订阅中移除 `log`，避免连接时重放无关用户标签的历史 console 内容；导航、realm、输入事件保持。显式携带 `contexts` / `userContexts` 的订阅原样转发，不伪造服务端回复。普通 scoped 接口不承诺全局 console 事件；已有日志采集授权的可信维护客户端可用 `openTransport` 第三参数 `{ bootstrapLogs: true }` 恢复 SDK 启动日志订阅。

AI Agent 入口见 [skill](../skills/firefox-nightly-automation/SKILL.md)。

## Skillshare

使用 Skillshare 时，其源目录中的同名位置可保留联接作为本机入口；本 skill 由独立仓库 Git 维护。部分版本不遍历源目录中的联接，客户端应直接联接原始 skill，不通过 collect/pull 复制维护。全局同步前检查 dry-run，确认不会覆盖客户端入口。通过联接访问时，skill 按真实路径定位工具根目录；刷新客户端技能列表后生效。
