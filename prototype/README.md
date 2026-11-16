# wx-viewer 原型

这里只是给 `D:\Doubao\wx_video_downloader` 参考的框架，**没有修改该目录**。

## 文件

- `wx-viewer.vbs`：无控制台启动 `wx-viewer.py`，单实例、日志、Python 3.14/pythonw 探测；
- `uia-scroll-probe.ps1`：实测 UIA 卡片数量、自动滚轮、去重统计；
- `uia_paginate.py`：Python 滚动分页采集器，可直接复制到 `tools/`；
- `paginate_viewer.py`：Tkinter 最小查看器，边滚边显示采集结果。

## 已跑通的工作版本

```powershell
pythonw prototype\paginate_viewer.py
```

它会：

1. 找到微信作者主页的活动 `page-profile`；
2. 读取该层所有 `click-box`（不裁剪视口）；
3. 用鼠标滚轮向下翻页；
4. 按 `时长|点赞|文案` 指纹增量合并；
5. 表格实时显示；
6. 结束后滚回顶部；
7. 输出 `prototype\work\uia_paginated.json`。

实测当前主页：

```text
total_count = 163
顺序翻页采集 = 163
页数 = 15
截断 = True
耗时 = 19.3s
```

结果证明：

> **知道总数 163 后，从顶部按视口顺序采集并在 163 条停止，是正确的。**  
> 但不能直接读整个 UIA 树再取前 163 条：树里会积累 2000+ 个旧页/推荐流/隐藏节点，前 163 条不一定是当前作者的内容。

关键修正：

- 只采集与 `page-profile` 视口相交的卡片；
- 采集前先用滚轮回到顶部；
- 每滚一屏，取当前可见的 10–15 张；
- 按 `时长|点赞|文案` 去重；
- 到达 `total_count` 立即停止，后面的内容可能已经进入推荐流；
- 输出最多 `total_count` 条。

## 关于“总数 163，直接截断行不行”

分两种情况：

- **只看当前作者列表**：可以。从顶部开始、一屏一屏采集，达到 163 就停。
- **读整个 UIA 树后取前 163**：不行。实测树里会积累到 2000+ 个节点，可能包含旧账号/历史页/推荐流；前 163 条不保证是当前作者的 163 条。

所以截断必须配合：

```text
活动 page-profile
+ 视口范围
+ 从顶部开始
+ 顺序滚动
+ total_count 停止
```

`object_id` 仍然是更可靠的最终主键；当前版本先用文案+时长+点赞指纹验证顺序。

## 实测滚屏结论（2026-11-16）

```text
page-profile 数量 = 1
click-box 卡片 = 315
可见卡片 = 10
ScrollPattern = 不可用
滚轮后 Y 整体移动 500px
```

说明：

1. **可以自动滚屏**，但 UIA 的 `ScrollPattern` 在 `page-profile` 上不可用，必须用鼠标滚轮；
2. UIA 树本身保留大量视口外卡片；
3. 315 > 163，不能直接按数量当全量；
4. 滚动没有让卡片总数增加（当前列表已经加载完），所以“滚动”主要用于加载更多，不是唯一数据来源。

## 集成建议

不要把 `uia_paginate.py` 放进每 15 秒的自动刷新里，否则每次刷新都会滚动微信。

建议：

```text
普通刷新：uia-collect.py（快速、视口）
全量同步：uia_paginate.py（按钮/一次性）
合并：card-resolve.py + object_id / tmp_key
```

把 `uia_paginate.py` 复制到豆包项目的 `tools/` 后，用：

```python
subprocess.run([sys.executable, "tools/uia_paginate.py",
                "--out", "work/uia_cards.json"])
```

替换一次性的 UIA 采集步骤即可。输出字段包含 `cards/index/duration/seconds/like/like_int/desc/rect/cover`，与现有 `card-resolve.py` 兼容。

## 已知限制

- 315 个节点不等于 163 条视频，仍要 object_id/活动层过滤；
- 重复时长/重复文案会误合并；
- 滚动依赖微信前台和鼠标位置；
- 自动滚屏会移动用户当前页面，结束时才恢复；
- 下载仍受“明文 MP4 头是否在内存”限制。

## 用法

```powershell
# 命令行分页
python prototype\uia_paginate.py --max-pages 12 --wait 0.8

# 只读当前批次，不滚屏
python prototype\uia_paginate.py --no-scroll

# 图形查看器
pythonw prototype\paginate_viewer.py

# 单独验证滚轮
pwsh -Sta -File prototype\uia-scroll-probe.ps1 -Steps 6
```

启动 `D:\Doubao` 的 viewer（复制 VBS 到其根目录后）：

```powershell
cscript //nologo wx-viewer.vbs
```
