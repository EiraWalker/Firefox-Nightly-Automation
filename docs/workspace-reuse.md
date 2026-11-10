# 复用一个 run 的连接与工作页，避免重复准备激活

## 结论与边界

现有 `run` 已支持一个任务函数内的长连接、多批次、异步等待。应首先复用它，而不是每个 DOM 检查点各发一次 CLI `run`。本说明不新增常驻服务、连接接管或个人标签操作，不改变默认策略。

- `src/automation.mjs:214–285`：一个 `run` 建连一次，创建一次 owned workspace，`await task(...)`，最终才关闭工作页和释放连接。
- `src/automation.mjs:104–112`：`start` 保留的是 Remote Control **服务**，不是活跃 BiDi **会话**；随后 `run` 仍需新连接。
- `src/workspace.mjs:78–134`：同一个 scoped `browser` 只暴露同一个工作页。`browser.newPage()` 首次只是已有页的别名，不是后台多标签接口。
- `src/workspace.mjs:212–249`：默认工厂每次创建 `type:'window', background:true`，要求新的窗口身份；不能传个人窗口/context 充当 owned workspace。
- `src/connection.mjs:144–150`：会话释放会断开自己的连接；不应通过伪造 release 或使用旧 sessionId 延长生命周期。

这消除的是**批次之间**重复 Allow 和新窗口创建的原因，不证明准备阶段或页面导航绝无焦点事件。Firefox 160 的 `background:true` 新窗口可能先激活再回焦；原生 Allow 也可能激活。`--no-workspace-activation` 只撤销创建期例外，不会把服务/连接准备转换成无激活路径。

## 可直接复用的调用形态

将业务小批次放在**同一任务文件的同一默认导出函数**中，调用现有 CLI 一次：

```js
// workflow.mjs：各步骤模块均由当前任务作者控制、审阅并获业务授权。
import inspect from './step-inspect.mjs';
import apply from './step-apply.mjs';
import verify from './step-verify.mjs';

export default async function workflow(browser, workspace) {
  await inspect(browser, workspace);
  // 可在此 await 本任务自己的本地决策/队列；不要 return 后再次 run。
  // 业务写入前仍须用最新读回核对目标与当前授权。
  await apply(browser, workspace);
  await verify(browser, workspace);
  return { completed: true };
}
```

```text
node.exe "<工具根目录>/cli.mjs" run --task "<绝对路径>/workflow.mjs" --hwnd <经重新核验的目标HWND>
```

该命令仅是获准准备后的调用方式，不是本次审计的执行许可。严格拒绝创建期激活可添加 `--no-workspace-activation`，但这可能在新窗口已产生焦点事件之后失败，**不是防止激活的预检开关**。若不允许任何初始激活且没有已拥有的工作页，不应为了试验运行它。

任务落盘仅保存已脱敏、业务需要的检查点；凭据/认证参数不得进入诊断或 stdout。任务出错不自动重放，先核对可能已完成的写入。动态任务模块不受 Node 沙箱保护，只能从当前任务自己的可信位置接收；上面的机制本身不是跨进程命令队列或安全远程执行接口。

长任务使用受跟踪后台进程，避免宿主前台命令硬超时杀死进程，遗留锁、工作窗口和共享会话。局部 DOM 求值保持短小。等待下一步时保留同一个未结束的任务函数；继续前使用 scoped 页操作的现有前后守卫。不要通过换基线、吞焦点事件、反复 SetFocus/恢复焦点或无限重连获得“通过”。任务结束后由原生命周期统一清理。

## 后台 owned tab 路由不是现成替代

Mozilla 的 `browsingContext.create({type:'tab', background:true, referenceContext:<owned context>})` 在已有明确 owned 窗口时是较窄的条件式路线。但当前工厂/原生登记契约要求新 HWND；Puppeteer 25.13 高层 `newPage` 不转发 `referenceContext`，scoped API 也没有安全的任意标签创建能力。因此没有可宣称已受守卫、已实机验证的现成 owned-tab 入口。

当前没有存活 owned workspace 时，不需要为本任务重写原生归属/标签基线或接管个人标签。可复用同一个工作页已经足以避免批次之间新建窗口和重连。若今后确需多后台标签，应单独设计精确 context 响应关联、owned 宿主 HWND 生命周期、标签变化授权、逐页守卫与失败回收，而非直接替换 `type` 字符串。

## 离线证据

本节新增回归测试按本次发布范围保留在维护机本地，不随代码与文档提交；以下命令和数量是本地验证记录，不是新克隆仓库现有测试集的承诺。

`tests/workspace-reuse.test.mjs` 对现有实现做特征/回归测试，使用真实 `NightlyAutomation`、`createTaskWorkspace` 与已安装 Puppeteer 编解码器；只在 BiDi 和原生边界使用内存模拟，无 socket、浏览器、原生窗口或输入：

1. 单次 `run` 的九轮异步 DOM 操作：连接、窗口、登记、关闭、释放各一次；同一 contextId/scoped page，求值显式 `userActivation:false`。
2. 九次单独 `run` 的对照：连接、窗口、关闭、释放各九次。
3. 等待下一批次期间连接/工作页不释放，恢复后仍使用原页。
4. 批次间守卫失败后不派发后续 DOM、不重连、不重放，sticky failure 不可修复，仍只清理 owned 页。
5. `start` 确实释放会话，不是跨命令长连接。

可复现命令（全部为已核对的离线 JS 测试；没有运行包含原生窗口夹具的完整 `npm test`）：

```text
node.exe --test --test-concurrency=1 tests/workspace-reuse.test.mjs tests/workspace.test.mjs tests/workspace-lifecycle.test.mjs tests/cli.test.mjs tests/connection-budget.test.mjs tests/connection-subscriptions.test.mjs
```

本轮结果：102 tests / 102 pass / 0 fail / 0 skipped。最初新增测试夹具曾因未绑定 `BidiDeserializer.deserialize` 的类接收者而失败；只修正测试调用，未改生产代码，也不把该失败冒充产品缺陷的 RED。已有长任务能力的验证不宣称是新修复的 RED/GREEN。

## 最小实机验收：仅协调后执行

**唯一额外前提**：当前没有存活 owned workspace，需用户明确允许一次初始化区间可能的激活（本次原生 Allow，以及一次独立 owned 窗口创建；服务已开则不启停）。不能从旧 skill 默认许可推导用户已经同意本次例外。若用户拒绝，保留暂停；现有工具没有可证明零激活的冷启动方案。无需用户逐批审批或手动反复置前。

1. 父代理确认无在途浏览器操作，核对当前 PID/创建代次、HWND、服务和锁；不能复用陈旧 HWND 或重置共享会话。
2. 获准后只起一个受跟踪 `run`，在新建的 owned 空白页做九轮无网络、无凭据 DOM 标记写入/读回，批次间有异步等待。不操作个人标签、不访问业务页、不发送付费 API 请求、不自动重试。
3. 整个任务只保留一套 token/contextId/HWND；初始登记完成后不得再建连、再出现 Allow、再建窗口或主动 focus。原始前台事件完整保留；不得启用 inspection 例外来掩盖自动激活。
4. 对照初始边界前后焦点收据，报告初始激活与后续激活分别计数。若登记后任何工具引起的激活/守卫失败，保留失败并结束，不恢复焦点掩盖干扰。
5. 结束时确认仅 owned 工作页关闭、自己的会话释放、锁释放，原有服务未被停止。此证明只覆盖空白页复用；Google Cloud 的导航/写入与 OAuth 还须在同一长任务方案下另行核验。

截至本说明，本轮没有连接浏览器、创建窗口、运行原生输入或进行真实焦点验收；不能宣称已实现全程零激活。
