# Hover 诊断

> **DeepSeek Harness** · 文档整理与验证

`tools/hover-diag.ps1` 不模拟鼠标、不改微信，只读取：

- `work\hud.log`
- `work\gui.log`

生成：

- `work\hover-diag.md`：统计报告
- 终端摘要

## 用法

```powershell
pwsh -File tools\hover-diag.ps1
```

或指定日志：

```powershell
pwsh -File tools\hover-diag.ps1 -HudLog work\hud.log -GuiLog work\gui.log -Out work\hover-diag.md
```

## 它回答什么

### 1. 为什么 hover 没进界面

按原因分类：

- `未达到 1 秒停留`
- `有停留，0 个媒体候选`
- `有候选但未绑定`
- `HUD 抛异常`
- `绑定成功但未入库`

`hud.log` 里的 `hover-cands` 会记录该次 hover 看到的候选 ID、最大 Range 和是否带 `m=`。

### 2. hover 时长与下载成功率

报告按“从 hover 开始到点击下载”的延迟分桶：

```text
0-1s / 1-2s / 2-3s / 3-5s / 5s+
```

每桶统计：

- 次数
- 首次成功
- 首次失败
- 最终成功

注意：绑定本身只要求停留 1 秒；这里分桶的是**用户点击下载时已经停留了多久**。

### 3. 第一次失败后如何恢复

对每个 `download-fail`：

- 失败原因（新版 GUI 日志会带 `reason=`）
- 之后是否再次 `download-start`
- 间隔多久
- 下一次是 `done` / `fail` / 仍在进行

## 建议的测试方法

1. 在作者主页选 5–10 条视频；
2. 分别按 1 秒、2 秒、3 秒、5 秒左右停留后点击下载；
3. 不要清缓存，跑完一轮；
4. 运行诊断脚本；
5. 对失败条目重新 hover/播放一次，再跑一轮，观察恢复路径。

## 限制

- 日志按 `HH:mm:ss` 记录，只适合单次连续会话；
- “清除缓存”会删除 GUI/HUD 日志，清理前的数据不会进入报告；
- 下载失败的具体原因需要新版 GUI 日志里的 `reason=`；
- 它不判断视频内容是否错误，只判断时长是否在下载流程中被拒绝。
