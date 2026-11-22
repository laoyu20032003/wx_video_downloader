# 播放窗 profile 作品弹层

> 来源：本地参考实现（豆包）2026-11-22。
> 文中的 `tools/...`、`work/...` 是参考目录里的探针和产物，**没有随本仓库复制**。
> 本仓库已落地的是 [viewer/cache_meta_parse.py](../viewer/cache_meta_parse.py) 的 `--live` 快照和 [viewer/cache_covers.py](../viewer/cache_covers.py) 的封面校验；本文只记录实验事实，不把参考工具当成本仓库入口。

## 入口与层级

在沉浸播放窗口点击作者 profile 头像后，右侧进入非 hover 的作者作品弹层；再次点击头像会切换到熟悉的 hover 作者窗口。

UIA 中该弹层的关键类名是带 Tailwind 后缀的完整类名，不能按裸类名精确匹配：

- `author-profile-area ...`：作者弹层容器；
- `scroll-ctn ... overflow-y-scroll ...`：CSS 滚动容器；
- `click-box`：作品卡片；
- `prev-i`：卡片封面图，UIA Name 为“封面”。

## 生命周期：进入 hover 后原弹层是否还存在

结论：视觉上像被替换，但节点不是简单销毁；原弹层至少会保留一部分 `author-profile-area`、`scroll-ctn` 和作品卡片。

核验方式：

1. `FindAll` 直接按类名计数时，结果可能漏掉 RawView 父节点，且类名不是裸 `author-profile-area`。
2. 从 `click-box` 元素通过 `RawViewWalker.GetParentElement` 向上走父链，可以回连到：
   - `scroll-ctn box-border ... overflow-y-scroll ...`；
   - `author-profile-area box-border ... overflow-hidden ...`；
   - `comment-panel ...`；
   - `flow-view ...`；
   - `page-layout ...`。
3. 当前一次样本中，15 个 `click-box`、15 个 `prev-i` 的父链均能回连到 `scroll-ctn` 和 `author-profile-area`。父容器 `CurrentIsOffscreen=0`，但视觉上被 hover 层覆盖或路由切换；卡片自身的 offscreen 状态会随界面状态变化。

因此，“被替换”更准确地说是展示层/层级/路由状态变化，不等于 DOM/UIA 节点全部销毁。元素数量在不同快照中会变化，历史样本曾出现 30、15、105 等计数，不能把某个数量当成固定作品数。

探针：`tools/profile_layer_diff.py`，当前样本：`work/profile_layer_diff_now.json`。

## UIA 可直接获得的信息

当前样本刷新后，未主动滚动时 UIA 挂载 15 张卡片，其中 8 张可见、7 张离屏。历史样本也曾在首批挂载 30 张，其中 8 张可见、22 张离屏。

每张卡片可直接读取：

- 时长，如 `00:31`、`00:17`、`00:14`；
- 点赞数；
- 标题/描述文本；
- 卡片矩形和离屏状态。

探针：`tools/profile_popup_probe.py`，输出：`work/profile_popup_probe.json`。

## UIA 不能直接获得的信息

UIA 卡片不直接暴露：

- 数值 oid/feed id；
- 20302 视频 URL；
- 20304/20350 封面 URL；
- 作者作品总数。

`scroll-ctn` 虽然有 CSS `overflow-y-scroll`，但容器不提供原生 `ScrollPattern`。卡片本身支持 `ScrollItemPattern`/`InvokePattern`，可通过 `ScrollIntoView` 驱动元素进入可视区域；这仍是后续滚动分页的重要入口。

## 内存证据

内存中可定位作者作品页 CGI：

- 路由：`/cgi-bin/micromsg-bin/pc_finderuserpage`；
- 相关直播路由：`/cgi-bin/micromsg-bin/pc_finderliveuserpage`；
- 场景：`scene=143`；
- 请求字段：`username`、`finder_username`、`object_id`、`last_buffer`、`need_fans_count`。

首次请求的 `last_buffer` 为空；后续请求携带非空游标，说明接口按页返回，当前 UIA 首批卡片不是可直接证明的全量作品。

UTF-16/ASCII 响应对象中可看到单条 feed 的完整结构：

- `id`/`object_id`；
- `nickname`；
- `username`；
- `object_desc.description`；
- 20302 视频 URL；
- `thumb_url`。

完整作品数组没有以可直接解析的 JSON 数组形式稳定驻留；V8 对象字段可能以压缩指针或数值形式存储，不能仅靠十进制字符串扫描恢复全部 oid。

## 进入 hover 后的保留对象

已知 profile oid `15060139184552353226` 在进入 hover 后仍能从 renderer 内存中找到，记录包含：

- `comment_scene=143`；
- `feed_pos=1`；
- 完整 20302 URL；
- 资源级字段 `encfilekey`、`m`、`uzid`；
- kvReport 中的 decodeKey；
- 20350 封面 URL。

同一 oid 可能在不同进程/不同上报位置出现多个 decodeKey 候选；下载时应按同流键（优先 `encfilekey + m`）去重，失败再轮试候选 key。

相关输出：

- `work/profile_hover_mem.json`；
- `work/profile_hover_dk.json`；
- `work/profile_hover_covers.json`；
- `work/profile_memory_extract.json`。

## 本地缓存封面实证

运行中的 Cache_Data 可以通过共享读方式快照，无需关闭微信：

- 快照工具：`tools/cache_live_snapshot.py`；
- 当前快照：`work/cache_snapshots/20261122_112238`；
- 解析条目：6719，错误 0；
- 资源码统计：20304=5435、20350=442、20302=18、20204=27。

11:15:19-20 的 profile 批次包含：

- 1 个 20350 完整封面；
- 15 个 20304 卡片封面；
- 15 个 20304 按文件/时间顺序对应 UIA 的 15 张卡片；
- 20350 是当前/首张卡片的完整封面。

提取工具：`tools/profile_popup_cache_extract.py`。

```powershell
& "C:\Users\ASUS\AppData\Local\Programs\Python\Python314\python.exe" "tools\profile_popup_cache_extract.py" --batch-index 205 --out-dir "work\profile_popup_15_covers"
```

输出：

- `work/profile_popup_15_covers/idx_000000.jpg` 至 `idx_000014.jpg`；
- `work/profile_popup_15_covers/full_000000.jpg`；
- `work/profile_popup_15_covers/profile_popup_covers.json`。

缓存中的 20302 视频响应头仍显示 `X-encflag=1`、`X-enclen=131072`，与现有 ISAAC64 解密链路一致。

## hover 模式下能否非交互滚动隐藏层

结论分两层：

1. **仅调用 `ScrollItemPattern.ScrollIntoView`：调用成功，但隐藏层不滚动、不触发分页。**
   - 初始 retained 卡片数 15；
   - 对最后一张离屏卡片连续调用 `ScrollIntoView`，返回 `ok`；
   - 调用后卡片矩形、offscreen 状态和数量均不变，连续两轮增长为 0；
   - 说明在非 hover 层没有 UIA/DOM focus 时，该调用更像被浏览器/无障碍层接受但没有实际驱动隐藏滚动容器。

2. **先 `SetFocus`，再 `ScrollIntoView`：可以程序化分页，无需鼠标、键盘或点击。**
   - 早期观察：`SetFocus` 没有把微信窗口抢到前台，截图时前台仍是豆包窗口；
   - **2026-11-22 复验：仍可能把微信 raise 到前台**，不能保证真正的后台；因此只作为备用方案；
   - 调用后卡片数从 15 增至 30；
   - 连续分页过程：30 → 45 → 60 → 75 → 90 → 105 → 111；
   - 最后一批仅增长 6，之后两次继续调用均保持 111，判定当前作者作品页到达末尾；
   - 前后 UIA class diff 中没有新增/删除 hover 相关类，仅 `click-box`、`prev-i` 和空类计数变化，说明 hover 展示结构仍保留，隐藏的非 hover 层被程序化滚动。

测试工具：`tools/hover_hidden_scroll_test.py`。

```powershell
# 无 focus：不触发实际分页
& "C:\Users\ASUS\AppData\Local\Programs\Python\Python314\python.exe" "tools\hover_hidden_scroll_test.py" --rounds 2

# 程序化 focus 后分页：可拿到当前样本全部 111 条
& "C:\Users\ASUS\AppData\Local\Programs\Python\Python314\python.exe" "tools\hover_hidden_scroll_test.py" --rounds 8 --focus-first
```

输出：

- `work/hover_hidden_scroll_test.json`：无 focus 对照；
- `work/hover_hidden_scroll_focus.json`：首次 focus 分页，15 → 30；
- `work/hover_hidden_scroll_focus_multi.json`：连续分页至 111；
- `work/hover_hidden_scroll_focus_tail.json`：末尾核验；
- `work/hover_hidden_scroll_final.json`：最终 111 卡片快照。

分页后重新快照并解析缓存：

- 缓存 entry：6770，解析错误 0；
- 资源码：20304=5488、20350=440、20302=18、20204=27；
- 本轮新增 90 个唯一 `m` 的 20304 封面 entry；
- 20302 数量不变，说明该过程只触发作品列表/封面分页，没有自动播放或新增视频流缓存。

边界：`SetFocus` 是 UIA 程序化调用，不是物理交互；但如果要求严格“零 focus 变化”，仅靠无 focus 的 `ScrollIntoView` 当前不能滚动隐藏层。

### 备用方案：SetFocus + ScrollIntoView

仅作为 `content.ScrollPattern` 不可用时的后备记录，不默认接入 viewer：

1. 在播放窗打开作者 profile 弹层；
2. 找到保留的 `author-profile-area` / `scroll-ctn` 下的 `click-box`；
3. 对目标卡片调用 UIA `SetFocus()`；
4. 再调用 `ScrollItemPattern.ScrollIntoView()`；
5. 等待 300–500ms，重新统计 `click-box` 数量/位置；
6. 重复直到卡片数不再增长，或目标卡片出现。

边界：

- `ScrollIntoView` 单独调用可能返回成功但不真正滚动；
- `SetFocus` 仍可能 raise 微信窗口到前台；
- 只能拿到 UIA 卡片，仍无 oid/20302 URL；
- 因此当前只记录方法，不替换 `content.ScrollPattern`。

## 结论

1. 进入 hover 后，原 profile 弹层不是确定性销毁；RawViewWalker 父链证明 `author-profile-area`/`scroll-ctn` 和卡片会保留。
2. UIA 可稳定读取首批卡片的位置、时长、点赞和描述，但不直接给出 oid/URL。
3. 无 focus 的 `ScrollIntoView` 对隐藏层不产生实际分页；`SetFocus + ScrollIntoView` 能程序化分页（15 → 111），但仍可能 raise 前台，只作备用记录。
4. 进入 hover 后，已驻留/已上报的 feed 对象可回出完整 20302 URL、decodeKey 和 20350 封面。
5. 本地 blockfile cache 可免费、离线地恢复 profile 卡片封面；20304 的顺序可映射 UIA 卡片序号。
6. `SetFocus + ScrollItemPattern.ScrollIntoView` 只作为 `content.ScrollPattern` 不可用时的备用方法记录；当前不接入自动采集。
