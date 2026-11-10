# 专用标签页能否缓解 Nightly 自动化问题

本文件保留研究阶段证据；后续获授权实施的默认行为与边界以[独立工作窗口](task-workspace.md)为准，实跑结果以[验证记录](../VALIDATION.md)为准。

取证日期：2026-10-24（UTC+08）。范围：当前自动化工具工作区、已安装 Puppeteer Core 25.13.0、本轮在线获取的 MDN/W3C 原始资料，以及本轮此前 CRC 校验提取的 Firefox 160.0a1 源码快照。后者不是对“最新 Nightly”的声明。

本轮仅研究：没有连接浏览器、创建或移动标签、改动生产代码、调用付费 API。下面的守卫实验使用合成快照，不是实机浏览器验收。

## 结论

**可行，也值得作为默认页面工作方式；但它解决的是“页面操作归属和隔离”，不能单靠多开一个标签就解决全局桌面守卫、原生连接确认或 privileged scope 限制。**

- 设置页、资料读取、DOM 表单等：优先创建任务自有的后台标签，直接保留 Page 对象。
- 需要与用户并行浏览、保持任务页为所选标签或需要视觉交互：更值得验证同一浏览器 context 中的独立、非最小化后台工作窗口，内部使用专用标签。
- 两者都必须配套 task ownership 与守卫作用域。否则用户在原窗口切页，当前实现依然可能中断。
- 当前 YouTube 插件尤其不能一律放到后台标签：其观看资格明确依赖页面可见性。

## 已核实的实现能力

### 当前依赖已经支持，不需要先更换框架

本机安装的 `puppeteer-core/package.json:3` 确认为 25.13.0。

- `node_modules/puppeteer-core/lib/puppeteer/api/Browser.d.ts:177–188` 定义了 `CreatePageOptions`，支持 `type: 'tab' | 'window'` 和 `background`。
- `.../bidi/Browser.js:263–264` 将 `newPage(options)` 转给默认 browser context。
- `.../bidi/BrowserContext.js:235–267` 将 `background` 传给 BiDi 创建接口，并直接返回已经取得的 Page。

因此，可以在设计上采用 `context.newPage({background: true})`，或 `context.newPage({type: 'window', background: true})`。这只是确认当前库接口和实现存在，**本轮没有实机验证它们在现有 profile、内部页及窗口策略下的完整行为**。

应使用获准目标所属的现有 browser context；不要为了隔离操作而默认创建全新/隐私 context，否则登录与容器状态可能不同。高层创建选项不提供指定已有 OS 窗口的参数；若必须落在某个现有窗口，需要进一步处理窗口映射或 BiDi 的 `referenceContext`，不能仅凭“新开标签”作保证。[S1][S2]

W3C 的 `browsingContext.create` 将 `background` 默认设为 false；后台创建必须显式指定。MDN 的扩展 API 中，`tabs.create` 的 `active` 与 `windows.create` 的 `focused` 也分别控制标签选择和窗口聚焦，不可混为同一个开关。[S1][S3][S4]

### 应直接持有 Page，而不是事后猜目标

设计建议：先创建空白专用页并取得 Page/稳定 context ID，再导航到已授权 URL，核对文档身份与所需 API。不要导航完成后仅按 URL、标题或标签位置重新寻找目标；重复 URL 与页面发现差异会造成歧义。

这有望减少此前“新开的设置页找不到 Puppeteer target”一类定位问题，但不构成对所有扩展内部页兼容性的保证。当前库的 `newPage` 自身也有 `Page is not found` 分支，需要实测而不是承诺不会失败。

## 对已知问题的影响

| 已知问题 | 同窗口专用后台标签 | 独立工作窗口中的专用标签 | 判断依据 |
| --- | --- | --- | --- |
| 误改、刷新或关闭用户正在使用的页面 | 可以显著减少，前提是只操作自有 Page | 同样可以，归属更清楚 | 页面句柄和清理目标隔离；设计推断 |
| 任务中导航、重试、清理时混淆目标 | 可以改善 | 可以改善 | 保留创建返回值和任务标识，而不是重新猜目标 |
| 用户切换原窗口标签导致 `F_DESKTOP_CHANGED` | 当前守卫仍会拦截 | 当前守卫仍会拦截 | `Get-Snapshot` 收集所有窗口；比较器无 task ownership 参数 |
| 创建工作窗口被判 `window-set` | 通常不新增 OS 窗口 | 若新增窗口跨越守卫采样点，会触发 | 比较器对窗口集合做全量比较；存在采样边界 |
| 原生 Allow、旧待授权框、其他客户端会话占用 | 不能单独解决 | 不能单独解决 | 属于连接/进程级状态，不是业务标签状态 |
| 启动 Remote Control 的按钮 offscreen | 按当前流程不能解决 | 按当前流程不能解决 | 工作页创建发生在服务准备和连接之后 |
| `browsingContext.activate` 对 privileged scope 不支持 | 不能消除限制 | 不能消除限制 | Firefox 按上下文权限与命令支持检查，不按标签是否专用检查 |
| YouTube 后台停发新翻译请求 | 可能反而触发这一正常策略 | 可作为非最小化、任务标签被选中的候选方案，仍需测 | 插件直接检查 `document.hidden` |

## 当前守卫为什么不会自动受益

已核实源码：

- `src/native.ps1:64–85` 的 `Get-Snapshot` 遍历所有 Nightly 浏览器窗口，而不只是 `--hwnd` 对应窗口。
- `src/native.ps1:87–131` 以全量窗口快照和焦点策略决定是否抛出 `F_DESKTOP_CHANGED`。
- `src/desktop-policy.ps1:17–45` 对所有窗口的集合、位置、最小化及所选标签进行比较。
- `src/automation.mjs:161–185` 通常在业务 callback 返回后执行原生 assert，CLI 还有最终检查。

已用实际 `Compare-DesktopSnapshot` 函数运行合成输入，结果为：

| 合成场景 | 当前比较结果 |
| --- | --- |
| 新后台标签不改变原窗口所选标签对应的快照 | 通过 |
| 任务使用另一个标签，但用户切换原窗口所选标签 | `tab-selection` |
| 检查点观察到额外工作窗口 | `window-set` |
| 任务已有独立窗口，用户切换原窗口所选标签 | 仍为 `tab-selection` |
| 新工作窗口已在下一检查点前关闭、当前快照恢复 | 窗口快照比较通过 |

最后一行不是绕过守卫的建议：现有比较器不记录所有中间窗口快照；原生焦点事件仍持续保留。创建并关闭完全发生在一个 callback 内，**不意味着必然失败，也不意味着已经证明不会抢焦点**。跨检查点复用工作窗口时，需要显式生命周期登记，而不是重新采纳任意桌面基线。

## 推荐的最小设计

以下是设计建议，尚未实现。

1. **增加 TaskWorkspace。** 记录创建返回的 Page、context/window ID、HWND 与浏览器进程代次、原 browser context、任务 token、预期来源及已授权操作；新建副本，不默认搬走或接管用户原标签。
2. **默认只操作自有页面。** 导航前后核对身份。对于有草稿、播放位置、正在执行流程的原页，不能假定新 URL 标签复制了这些运行状态。
3. **分层守卫。** 连接准备继续保留原生确认框、进程、服务归属和焦点审计。页面阶段对任务自有资源及工具造成的操作进行约束；在任务确实只使用自有页面时，用户原窗口正常切页不应直接判为任务失败。保留原始观察，不能简单删除事件或全局关闭检查。
4. **显式登记窗口生命周期。** 只允许由本任务创建并验证的窗口/标签增加、导航和关闭；未知窗口、任务资源被用户关闭或替换、跨来源越权均需明确处理。只清理本任务仍拥有的对象。
5. **显式设置后台参数。** 不依赖默认值，也不把 `background`、`active`、`focused`、`minimized` 当成同义词。新窗口先验证非最小化与聚焦状态，不能只信创建参数。
6. **不要声称账号/安全隔离。** 同一 context 的专用页主要隔离操作目标，不隔离账号、扩展设置或 Remote Control 会话。

## YouTube 插件的特别限制

`E:/plugin/immersive-translate-local/src/content/main.js:25–28` 只在启用、字幕源已确认、视频播放且页面非隐藏、非广告时报告 active；同文件 `:425` 监听 `visibilitychange`。

因此，把实际视频放进未选中的后台标签，会使 `!document.hidden` 不满足。后台停止新增翻译请求是当前有意的资源/费用约束，不能误诊为插件故障。设置页配置和读取可以采用专用后台标签；实时字幕/计时/播放追赶验收必须另外核验可见性与观看资格。

MDN 明确区分窗口失焦和页面隐藏，并说明后台页面可能受到计时器、动画调度限制。独立非最小化窗口中的所选标签是值得测试的候选，但不等于已保证在本机遮挡、浏览器策略及页面逻辑下始终 visible。[S5]

## 建议的后续验证范围

### 先分开处理连接生命周期风险

独立的工具复查返回后，本轮使用仅含内存 native/protocol/store 替身的脚本，调用当前真实 `NightlyAutomation` 模块复核了两项风险，没有连接或关闭真实服务：

- **P1，服务代次归属：** `src/service-stop.mjs:28–30` 在预检断连时返回不支持，`src/automation.mjs:53–60` 随后回退原生关闭前未再次核验归属。合成场景把 service-1 在预检期间替换为 service-2，实际调用落到 service-2，仍返回 stopped 并清除归属。
- **P2，关闭读回：** `src/automation.mjs:42–48` 在监听消失且 `toolbarRunning=false` 时接受成功，没有要求 `toolbarAvailable=true`。合成场景的工具栏不可读，仍返回 stopped 并清除归属。

这两项不能通过专用标签或窗口消除，应先独立修复再把服务清理视为完整安全路径。当前研究没有修复生产代码，也没有将模拟结果描述为真实服务误关。复查另报同版本禁用扩展的归档收据边界，本轮尚未独立复核。

若另行要求实施，最小实验应比较同窗口后台标签与独立后台窗口，使用合成站点而非真实账号/付费请求：

- 创建、导航、关闭后，用户原标签 URL、选择和窗口聚焦保持预期。
- 用户正常切换原窗口标签时，任务只在自有页面继续；源代码/上下文无越权。
- 相同 URL 多页并存、用户关闭任务页、页面重定向时不误认或误关其他页面。
- 分别记录 visibilityState、hasFocus、事件 isTrusted、播放资格与请求是否实际发出。
- 内部扩展页能力、原生站点权限确认、服务启动/清理独立验证，不混作“专用页已解决”。

## 原始资料

独立只读复核已完成，确认当前全窗口守卫不会因专用 tab/window 自动缩小范围，并支持显式 ownership/lifecycle 分域。复核未进行浏览器操作。本报告保留了额外的采样边界限定：新窗口跨检查点可触发 window-set，而不是断言任意自建窗口必然失败。

本轮在线获取均为 HTTP 200。通用抽取器因地址分类拒绝访问后，通过正常 HTTPS 从维护者原始仓库读取；未使用账号、cookie 或授权头。

- [S1] W3C WebDriver BiDi：`browsingContext.create`，参数与聚焦步骤。`https://raw.githubusercontent.com/w3c/webdriver-bidi/main/index.bs`（本轮读取第 4301–4404 行）。
- [S2] 已安装 Puppeteer Core 25.13.0：本报告列出的 package.json、Browser.d.ts、bidi/Browser.js 与 BrowserContext.js。
- [S3] MDN WebExtensions tabs.create：`https://raw.githubusercontent.com/mdn/content/main/files/en-us/mozilla/add-ons/webextensions/api/tabs/create/index.md`。
- [S4] MDN WebExtensions windows.create：`https://raw.githubusercontent.com/mdn/content/main/files/en-us/mozilla/add-ons/webextensions/api/windows/create/index.md`。
- [S5] MDN Page Visibility API：`https://raw.githubusercontent.com/mdn/content/main/files/en-us/web/api/page_visibility_api/index.md`。
- [S6] 本轮此前 CRC 校验提取的 Firefox 160.0a1 `RootBiDiModule.sys.mjs:156–189` 与 `modules/root/browsingContext.sys.mjs:332–340,662–790`：权限及命令支持检查、后台创建和 referenceContext 行为。
