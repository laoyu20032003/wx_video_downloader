# wx-viewer 原型

这里只是给 `D:\Doubao\wx_video_downloader` 参考的框架，**没有修改该目录**。

## 文件

- `wx-viewer.vbs`：无控制台启动 `wx-viewer.py`，单实例、日志、Python 3.14/pythonw 探测；
- `uia-scroll-probe.ps1`：实测 UIA 卡片数量、自动滚轮、去重统计。

## 实测结论（2026-11-16）

对当前微信作者主页：

```text
total_count = 163
page-profile 数量 = 1
click-box 卡片 = 315
可见卡片 = 10
卡片 Y 范围 = -2859 .. 18847
ScrollPattern = 不可用
```

自动滚轮测试：

```text
滚轮前：tree=315 unique=315 y=-2859..18847
滚轮后：tree=315 unique=315 y=-3359..18347
再滚：  tree=315 unique=315 y=-3859..17847
```

说明：

1. **可以自动滚屏**，但 UIA 的 `ScrollPattern` 在 `page-profile` 上不可用，必须用鼠标滚轮/SendInput；
2. 每滚一格，UIA 树里的卡片 Y 整体移动 500px，说明滚轮确实驱动了页面；
3. UIA 树本身已经保留大量**视口外卡片**，不是只有 10 张；
4. 当前 315 张 > 页面标注 163 条，说明树里混有旧页/隐藏层/广告/重复节点，不能直接按数量当全量；
5. 滚动没有让卡片总数增加（当前列表已经加载完），所以“滚动”主要用于加载更多，不是唯一的数据来源。

## 建议的采集器结构

```text
读取活动 page-profile 的全部 click-box（不裁剪视口）
        ↓
按 (时长, 点赞, 文案) 指纹去重
        ↓
用 renderer 记录回填 object_id/nonce
        ↓
滚轮滚动一屏 → 等待 → 再采集
        ↓
按 object_id 合并 slots；没有 oid 的先用 tmp_key
```

不要：

- 只读可见区域；
- 用 `click-box` 数量直接当 total_count；
- 用 UIA 的 DOM index 当最终槽位号；
- 依赖 `ScrollPattern`。

## 用法

把两个文件复制到目标项目根目录后：

```powershell
cscript //nologo wx-viewer.vbs
```

或：

```powershell
pwsh -Sta -File uia-scroll-probe.ps1 -Steps 6 -Out work\scroll_probe.json
```

`wx-viewer.vbs` 默认找同目录的 `wx-viewer.py`；也可以：

```powershell
cscript //nologo wx-viewer.vbs "D:\Doubao\wx_video_downloader\wx-viewer.py"
```
