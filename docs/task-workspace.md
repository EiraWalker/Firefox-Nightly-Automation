# 独立工作窗口

Firefox 160.0a1 的 `background:true` 新窗口路径可能先激活新窗口再回焦原窗口。用户已明确允许新建工作窗口时短暂激活；默认仅放行从创建开始到原生归属登记完成之间、精确属于已验证新 HWND 的激活事件。默认仍拒绝登记后的激活或工作窗口停留前台；可信调用方可在用户明确授权查看工作窗口时，单独启用下述 inspection 选项。原始事件与全局检查如实保留，这不是零激活方案。

[返回使用参考](reference.md) · [后台页面验收](background-acceptance.md)

`run --task` 默认在现有 Nightly、同一个 browser context 中创建独立、非最小化的后台工作窗口。用户继续在自己的窗口工作；用户窗口的切页、移动、最小化、增减和其他应用活动不是任务失败条件。浏览器退出、连接失效、工作窗口身份丢失或原生控件不可用仍会使任务失败。

## 任务入口

任务默认导出异步函数，参数为 `(browser, workspace)`。`workspace.page` 是已经创建并登记的工作页，`workspace.info` 是无正文的归属元数据。第一个参数是任务范围的 browser-like 接口，不是全局 Puppeteer Browser：页面发现仅面向自己的工作页，保留浏览器版本和连接状态等必要元数据；不提供全局连接、关闭浏览器或任意接管原标签的能力。不承诺完整 Puppeteer API 兼容。

1. 直接使用 `workspace.page` 操作当前任务已授权的目标。导航后核对完整 URL、标题和实际业务就绪条件。
2. 任务只返回业务结果。工具负责关闭工作窗口、按代次处理自己新开的服务并释放自己的连接。
3. 任务失败也执行归属受限的清理。清理失败保留任务已返回的结果、工作窗口状态及错误码，整体仍失败；多阶段失败按 `cleanupErrors` 逐项保留。不要因此自动重放业务写入。

当前任务明确不允许新工作窗口激活时，对 `run` 添加 `--no-workspace-activation`。它只撤销工作窗口创建期的例外，不改变服务开启/连接确认的授权；当前 Firefox 可能因无法严格后台创建而明确失败，不回退接管用户窗口。程序调用可用 `run(task, {allowWorkspaceCreationActivation:false})`。

工作窗口共享原 profile/context 的登录、扩展与存储，不是隐私窗口，也不是账号或恶意 Node.js 代码的安全沙箱。插件设置等共享存储写入仍按业务授权执行，不能因页面独立而当作无副作用。

### 明确授权查看工作窗口

`createTaskWorkspace(browser, native, {allowInspectionActivation:true})` 是可信工厂的显式选项，默认 `false`，且必须是布尔值。它被原样转发给原生 `beginWorkspace`，不新增 CLI 开关，也不改变 `run` 或其他命令的默认策略。已获用户授权的自定义工厂可以调用：

```js
createTaskWorkspace(browser, native, { ...options, allowInspectionActivation: true });
```

许可仅覆盖已完成唯一归属登记的 owned HWND，从登记完成的事件边界开始，到显式关闭并确认 HWND 消失的生命周期边界结束。活跃窗口仍需核对 PID、进程代次与窗口 cookie；同 HWND 的异 PID 事件不能使用 inspection 例外。登记前的事件不能追认，闭窗后或 HWND 被复用后的新事件也不计入例外。其他用户窗口继续按既有 scoped 策略仅观察，不被收编为 inspection 窗口。

启用后，用户点开此工作窗口或切走再回来，本身不再产生 `F_DESKTOP_CHANGED`，不会仅因查看而进入失败清理；任务仍可在自己的 DOM 上继续执行。正常任务完成后的归属清理照常执行。这不是激活来源检测：OS 前台事件不能证明是用户点击，而不是站点、脚本或其他程序发起；授权的是这个已验证 owned-window 的激活范围，而非“只放行已识别的用户点击”。

任务代码继续后台运行，不主动抢焦点。scoped `page.bringToFront()` 仍禁止；`page.evaluate` 仍显式使用 `userActivation:false`。窗口身份、正常位置/还原模式、观察可用性及 BiDi 页面归属仍检查，也不吞掉其他错误。选中标签变化仅观察，不单独中断任务；它不授予窗口激活权限。仅最小化/还原不再阻断工具操作，规则见[最小化窗口](minimized-windows.md)。inspection 不是自动播放、音频静音或可信输入能力的替代品。

## 归属与检查

- 创建前登记随机任务 token、已有 HWND 集合和浏览器进程代次。新窗口的空白页临时设置唯一标题标记；仅接纳本次新建、同进程同代次且唯一匹配的原生窗口。已有用户窗口不能被收编。
- 同时保留工作页的 BiDi context 和 window 身份。读取或清理时验证归属，不按 URL 或“最近一个空白页”猜测对象。
- 工作窗口有单独的保护快照。身份、真实位置/还原模式仍受检查；选中标签与 provider 差异仅观察，不重设快照。用户其他窗口只观察。工作窗口可以最小化，DOM/页面截图不要求恢复；真实移动、缩放仍不被授权。切换标签不会收编新页面，任务继续操作原 owned context。明确启用 inspection 时可以查看该窗口。
- 创建、关闭仅允许登记对象的生命周期变化。原始全局基线、快照差异和前台事件继续保留；`windowsStable=false` 等原始观察不自动表示工作窗口检查失败。以作用域判定和实际 `lastFailure` 为准。
- `workspaceCreationActivationAllowed` 与 `workspaceCreationActivationEventCount` 单独报告创建期限定例外。许可不会延伸到任务执行、关闭服务或其他窗口，不覆盖任务窗口的身份或真实几何保护；标签选择仅观察，最小化显示状态依其单独策略判断。
- `inspectionActivationAllowed` 表示本次登记历史中明确授权过 inspection，不是当前仍拥有窗口的证明；`inspectionActivationEventCount` 单独统计登记后、精确 HWND/PID 与有效 owned 生命周期内的许可事件，和创建期计数互不混用。关闭后保留历史计数，新增的闭窗后事件不再增加此计数。原始前台事件及全局策略结果不删除、不改写，基线不重设，已有失败历史继续保留；原始全局策略为 `false` 而 scoped 策略为 `true` 是允许的诚实收据。
- 原生确认仍要求唯一完整结构、同进程和本次连接归属，记住决定保持未勾选。独立窗口不补充 system access，也不消除原生控件 offscreen 或命令不支持。
- `install`、`verify`、`start`、`stop` 不执行网页任务，保留原有路径；本次并行工作窗口策略适用于 `run`。不要把本功能当作放宽所有命令的全局开关。

## 页面与视频验收

维护机本地的 `examples/workspace-check.mjs` 可在工具自己的空白页写入并反复核验测试标记，不读取用户网页、不请求远程翻译 API；该验收示例按本次发布范围未提交。运行期间用户可以正常使用自己的窗口；测试器不主动替用户切换或操作原窗口。

视频页的真实 `document.visibilityState` 与被测业务资格分别读回。YouTube 插件现已区分 DOM 遮挡与浏览器选中播放页：所属窗口未最小化、标签选中且有效，才可能授权新请求；暂停、切页、最小化和未知状态仍停止新增工作。独立窗口不能伪造可见性，也不等于字幕业务已经通过。

scoped `page.evaluate` 使用 owned context 的 BiDi 求值，并显式设置 `userActivation:false`，前后均核验归属与原生守卫。只支持可安全序列化的数据型参数/返回，不提供 handles 或原始连接；无法支持的值明确报错。需要播放等用户手势时，在已核对的 owned 页通过受守卫的可信浏览器输入完成，不将普通求值伪装成手势。此默认值不覆盖其他 Puppeteer 方法内部行为，仍以实际守卫收据为准。

实际离线与实机结果见 [验证记录](../VALIDATION.md)。源码或模拟测试通过不等于已经验证当前日用 Nightly 的全部并发行为。

inspection 选项目前通过离线测试（含实际 workspace JS 与原生函数/dispatch 的假 Win32/UIA 联合回放）；尚未进行真实浏览器用户点开工作窗口的验收。
