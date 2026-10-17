# Nightly 远程控制

## Language

**主窗口**：
承载标签页、网页内容和浏览器工具栏的 Firefox Nightly 窗口。
_Avoid_: 确认框

**Remote Control 面板**：
Nightly 工具栏中用于查看和切换远程控制服务状态的面板。
_Avoid_: 远程调试确认框

**原生连接确认框**：
Firefox 请求用户允许或拒绝远程控制连接的浏览器原生弹窗。
_Avoid_: Remote Control 面板、网页弹窗

**本次连接确认框**：
本工具发起当前连接时新出现、对应这次待批准连接的原生连接确认框。
_Avoid_: 所有远程调试请求
