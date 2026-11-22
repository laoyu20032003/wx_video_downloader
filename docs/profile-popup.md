# 播放窗 profile 作品弹层

> 来源：本地参考实现（豆包）2026-11-22，更新于 17:25。
> 文中的 `tools/...`、`work/...` 是参考目录里的探针和产物，**没有随本仓库复制**。
> 本仓库已落地的是 [viewer/cache_meta_parse.py](../viewer/cache_meta_parse.py) 的 `--live` 快照和 [viewer/cache_covers.py](../viewer/cache_covers.py) 的封面校验；`viewer/uia_scan.py` 的扫描分页已改用无 focus 的 `ScrollIntoView`（`content.ScrollPattern` 的 Scroll 会 raise，只在 find_card 精确滚动时保留）。

## 入口与层级

在沉浸播放窗口点击作者 profile 头像后，右侧进入非 hover 的作者作品弹层；再次点击头像会切换到熟悉的 hover 作者窗口。

UIA 中该弹层的关键类名是带 Tailwind 后缀的完整类名，不能按裸类名精确匹配：



* `author-profile-area ...`：作者弹层容器；

* `scroll-ctn ... overflow-y-scroll ...`：CSS 滚动容器；

* `click-box`：作品卡片；

* `prev-i`：卡片封面图，UIA Name 为 “封面”。

## 生命周期：进入 hover 后原弹层是否还存在

结论：视觉上像被替换，但节点不是简单销毁；原弹层至少会保留一部分 `author-profile-area`、`scroll-ctn` 和作品卡片。

核验方式：



1. `FindAll` 直接按类名计数时，结果可能漏掉 RawView 父节点，且类名不是裸 `author-profile-area`。

2. 从 `click-box` 元素通过 `RawViewWalker.GetParentElement` 向上走父链，可以回连到：

* `scroll-ctn box-border ... overflow-y-scroll ...`；

* `author-profile-area box-border ... overflow-hidden ...`；

* `comment-panel ...`；

* `flow-view ...`；

* `page-layout ...`。

1. 当前一次样本中，15 个 `click-box`、15 个 `prev-i` 的父链均能回连到 `scroll-ctn` 和 `author-profile-area`。父容器 `CurrentIsOffscreen=0`，但视觉上被 hover 层覆盖或路由切换；卡片自身的 offscreen 状态会随界面状态变化。

因此，“被替换” 更准确地说是展示层 / 层级 / 路由状态变化，不等于 DOM/UIA 节点全部销毁。元素数量在不同快照中会变化，历史样本曾出现 30、15、105 等计数，不能把某个数量当成固定作品数。

探针：`tools/profile_layer_diff.py`，当前样本：`work/profile_layer_diff_now.json`。

## UIA 可直接获得的信息

当前样本刷新后，未主动滚动时 UIA 挂载 15 张卡片，其中 8 张可见、7 张离屏。历史样本也曾在首批挂载 30 张，其中 8 张可见、22 张离屏。

每张卡片可直接读取：



* 时长，如 `00:31`、`00:17`、`00:14`；

* 点赞数；

* 标题 / 描述文本；

* 卡片矩形和离屏状态。

探针：`tools/profile_popup_probe.py`，输出：`work/profile_popup_probe.json`。

## UIA 不能直接获得的信息

UIA 卡片不直接暴露：



* 数值 oid/feed id；

* 20302 视频 URL；

* 20304/20350 封面 URL；

* 作者作品总数。

`scroll-ctn` 虽然有 CSS `overflow-y-scroll`，但容器不提供原生 `ScrollPattern`。卡片本身支持 `ScrollItemPattern`/`InvokePattern`，可通过 `ScrollIntoView` 驱动元素进入可视区域；这仍是后续滚动分页的重要入口。

## 内存证据

内存中可定位作者作品页 CGI：



* 路由：`/cgi-bin/micromsg-bin/pc_finderuserpage`；

* 相关直播路由：`/cgi-bin/micromsg-bin/pc_finderliveuserpage`；

* 场景：`scene=143`；

* 请求字段：`username`、`finder_username`、`object_id`、`last_buffer`、`need_fans_count`。

首次请求的 `last_buffer` 为空；后续请求携带非空游标，说明接口按页返回，当前 UIA 首批卡片不是可直接证明的全量作品。

UTF-16/ASCII 响应对象中可看到单条 feed 的完整结构：



* `id`/`object_id`；

* `nickname`；

* `username`；

* `object_desc.description`；

* 20302 视频 URL；

* `thumb_url`。

完整作品数组没有以可直接解析的 JSON 数组形式稳定驻留；V8 对象字段可能以压缩指针或数值形式存储，不能仅靠十进制字符串扫描恢复全部 oid。

## 进入 hover 后的保留对象

已知 profile oid `15060139184552353226` 在进入 hover 后仍能从 renderer 内存中找到，记录包含：



* `comment_scene=143`；

* `feed_pos=1`；

* 完整 20302 URL；

* 资源级字段 `encfilekey`、`m`、`uzid`；

* kvReport 中的 decodeKey；

* 20350 封面 URL。

同一 oid 可能在不同进程 / 不同上报位置出现多个 decodeKey 候选；下载时应按同流键（优先 `encfilekey + m`）去重，失败再轮试候选 key。

相关输出：



* `work/profile_hover_mem.json`；

* `work/profile_hover_dk.json`；

* `work/profile_hover_covers.json`；

* `work/profile_memory_extract.json`。

## 本地缓存封面实证

运行中的 Cache\_Data 可以通过共享读方式快照，无需关闭微信：



* 快照工具：`tools/cache_live_snapshot.py`；

* 当前快照：`work/cache_snapshots/20261122_112238`；

* 解析条目：6719，错误 0；

* 资源码统计：20304=5435、20350=442、20302=18、20204=27。

11:15:19-20 的 profile 批次包含：



* 1 个 20350 完整封面；

* 15 个 20304 卡片封面；

* 15 个 20304 按文件 / 时间顺序对应 UIA 的 15 张卡片；

* 20350 是当前 / 首张卡片的完整封面。

提取工具：`tools/profile_popup_cache_extract.py`。



```
& "C:\Users\ASUS\AppData\Local\Programs\Python\Python314\python.exe" "tools\profile_popup_cache_extract.py" --batch-index 205 --out-dir "work\profile_popup_15_covers"
```

输出：



* `work/profile_popup_15_covers/idx_000000.jpg` 至 `idx_000014.jpg`；

* `work/profile_popup_15_covers/full_000000.jpg`；

* `work/profile_popup_15_covers/profile_popup_covers.json`。

缓存中的 20302 视频响应头仍显示 `X-encflag=1`、`X-enclen=131072`，与现有 ISAAC64 解密链路一致。

## hover 模式下能否非交互滚动隐藏层

结论经历了两轮实证修正：

1. **早期样本：无 focus 的 `ScrollIntoView` 未分页，`SetFocus + ScrollIntoView` 成功。**
   - 初始 15 张卡片；仅调用无 focus `ScrollIntoView` 时，两轮均无增长；
   - 加 `SetFocus` 后，卡片从 15 分页到 111，末批 6 条，之后无增长；
   - 当时确认 `SetFocus` 没有把微信窗口抢到前台。

2. **新 hover 样本：无 focus 的 `ScrollIntoView` 可以静默分页。**
   - 新账号首批 15 张卡片，位于播放器内 `author-profile-area`；
   - 第 1 次无 focus 调用先把末卡滚动到可见位置，卡片数不变；
   - 第 2 次调用后 15 → 30，之后全程不调用 `SetFocus`，连续分页到 442；
   - 最后一批增长 7 条，随后两次无增长，判定到达末尾；
   - 测试后前台窗口仍为豆包，不是微信；全程没有鼠标、键盘或窗口前置。

因此，“无 focus 不能分页”不是通用结论；在当前 hover 播放器的 `author-profile-area` 中，无 focus 的 `ScrollItemPattern.ScrollIntoView` 已能驱动前端继续请求。需要注意：该方法不会 raise/focus 窗口，但会改变内部滚动位置；如果要求连滚动位置都完全不变，只能继续突破直接 JSBridge/原生 CGI 调用。

测试工具：`tools/hover_hidden_scroll_test.py`。

```powershell
# 静默无 SetFocus 分页
& "C:\Users\ASUS\AppData\Local\Programs\Python\Python314\python.exe" `
  "tools\hover_hidden_scroll_test.py" --rounds 12
```

### 自动采集器：profile_auto_collect.py

`tools/profile_auto_collect.py` 已把实验性分页固化为可复用采集器，并默认使用静默无 focus 模式。它同时支持：

- 播放器内 `author-profile-area` 作品弹层；
- 独立 `page-profile` 作者主页。

所需工具/依赖：

- Windows 自带 UI Automation / `UIAutomationCore.dll`；
- Python `comtypes`：调用 UIA 和 `ScrollItemPattern.ScrollIntoView`；
- Python `psutil`：识别微信进程；
- 不需要代理/CA、DLL 注入、鼠标键盘模拟或付费组件。

执行：

```powershell
& "C:\Users\ASUS\AppData\Local\Programs\Python\Python314\python.exe" `
  "tools\profile_auto_collect.py" `
  --out "work\profile_auto_collect.json"
```

停止条件：连续 `--stable-rounds` 次无增长，默认 2 次。旧场景如需 focus 兜底，可显式加 `--use-focus`。

新账号 442 条样本的请求与内存覆盖率：

- 唯一 JSBridge `request_id`：40 个，其中 11 个空游标、29 个带游标请求；
- renderer 堆中稳定 oid 记录：31 条；
- 显式 `index -> oid`：14 条；
- 含 20302 URL 的 oid：21 条；
- decodeKey/report 记录：35 条，覆盖 22 个唯一 oid；
- 封面分组：183 组，其中 61 组带 oid。

因此下一阶段需要的是“逐页内存采样器”：每次 UIA 卡片数增长后立即扫描 renderer，尽量在 V8 GC 前捕获新页 feed 对象，再按位置、时长、点赞和标题校验；若仍无法全量回出，再评估页面上下文 JSBridge 插桩或更底层 V8 堆对象解析。

### 未聚焦、部分遮挡的独立 page-profile

新样本直接处于未聚焦且部分遮挡的 hover 窗口，只读快照显示容器为独立 `page-profile`，初始 30 张卡片，其中 12 张可见、18 张离屏。

默认静默采集器全程不调用 `SetFocus`，仅对末卡调用 `ScrollItemPattern.ScrollIntoView`：

- 分页路径：30 → 45 → 60 → 75 → 90 → 105 → 120 → 135 → 150 → 165 → 180；
- 每轮增长 15 张，共 10 次分页；
- 最后两轮无增长，停止在 180 张；
- 测试前后前台窗口均为 `Doubao.exe`，微信没有被 raise/focus；
- 最终 UIA：12 张可见、168 张离屏。

最终内存驻留：

- oid 记录：50 条，唯一 oid 50 个；
- 显式 `index -> oid`：12 个；
- 20302 URL：最终扫描未稳定驻留；
- decodeKey/report 记录：31 条，覆盖 23 个唯一 oid；
- 封面记录：143 条，覆盖 47 个唯一 oid，对应 143 个资源键。

这证明无 focus 静默路径不只适用于播放器内 `author-profile-area`，也适用于未聚焦、部分遮挡状态下的独立 `page-profile`。

### 完全遮挡的极限场景

新样本只有 hover 窗口，且窗口完全被其他窗口遮挡、没有 focus。只读 UIA 仍可枚举到 15 张卡片，其中 8 张在 UIA 视口内、7 张离屏。这说明 UIA 的 `CurrentIsOffscreen` 只反映页面/视口状态，不感知本机窗口是否被其他窗口完全覆盖。

静默测试结果：

1. 对末卡调用无 focus 的 `ScrollItemPattern.ScrollIntoView`：首轮会改变内部滚动位置，但卡片数保持 15；第二轮仍无增长。
2. 无 focus 执行“首卡 → 末卡”的强制内部滚动两轮，卡片数始终为 15。
3. 通过 Win32 `PostMessageW` 向该窗口直接投递 12 次 `WM_MOUSEWHEEL`，不改变焦点，卡片数仍为 15。
4. UIA 树中没有出现 `no-more` / “没有更多了”节点，因此不像是正常首包即末页。
5. 测试后前台窗口仍为 `Doubao.exe`，微信没有被 raise/focus。

`flue.dll` 中存在完整 Chromium 特性字符串：

- `CalculateNativeWinOcclusion`
- `ApplyNativeOcclusionToCompositor`
- `AlwaysTrackNativeWindowOcclusionForTest`

结合“无 no-more 节点、无后续分页、部分遮挡可分页、完全遮挡不可分页”的现象，当前最符合证据的解释是：Chromium 原生窗口遮挡检测在完全遮挡时抑制/节流合成与滚动后续处理，导致前端懒加载指令没有继续触发 `FinderUserPage`。

**能力边界：无 focus 可以覆盖未聚焦和部分遮挡，但完全遮挡是当前 UIA/PostMessage 静默路径的极限；若要继续突破，需要直接调用页面上下文 JSBridge 或 V8/原生层，而不是依赖滚动与合成。**

### 屏幕外 + 屏幕内完全遮挡的混合场景

新样本窗口一部分在屏幕外，一部分在屏幕内，且屏幕内区域又被其他窗口完全遮挡。实测窗口矩形为 `[1460,13,2333,973]`；屏幕宽度为 1920，因此右侧 413 px 位于屏幕外，剩余屏幕内区域被完全遮挡。

只读 UIA 仍可枚举 15 张卡片，初始页面视口状态为 12 张可见、3 张离屏。这再次证明 UIA 的 `CurrentIsOffscreen` 不感知真实窗口遮挡，只按页面/视口状态返回。

静默测试结果：

1. 无 focus `ScrollIntoView` 两轮：首轮改变内部滚动位置，第二轮末卡进入页面视口，但卡片数始终为 15。
2. 无 focus 执行“首卡 → 末卡”强制滚动两轮：卡片数仍为 15。
3. `PostMessageW` 直接投递 12 次 `WM_MOUSEWHEEL`：卡片数仍为 15。
4. UIA 树没有 `no-more` / “没有更多了”节点。
5. 测试后前台仍为 `Doubao.exe`，微信没有被 raise/focus。

最终内存驻留：

- oid 记录：37 条，唯一 oid 37 个；
- 显式 `index -> oid`：11 个；
- 20302 URL：未稳定驻留；
- decodeKey/report 记录：30 条，覆盖 27 个唯一 oid；
- 封面记录：52 条，覆盖 17 个唯一 oid。

结论：只要屏幕内可见区域被完全遮挡，即使窗口另有一部分位于屏幕外，行为仍与“完全遮挡”一致，当前滚动/合成路径不会触发后续 `FinderUserPage`。

## 网络请求 / 响应：JSBridge 而不是普通 XHR

### 调用链

前端 bundle 中的实际链路已经闭合：



1. profile store 构造 `username`、`objectId`、`finderUsername`、`lastBuffer`、`sessionBuffer` 等参数。

2. service 包装为 `{name:"FinderUserPage", data:{finderBasereq:...}}`。

3. `ExtTransferService.computeParams()` 将下划线化后的请求放进：

* `req_json`：JSON 字符串；

* `url`：`/cgi-bin/micromsg-bin/pc_finderuserpage`；

* `cgi_cmdid`：CGI 地图中为 6624；

* `h5AuthToken`、`is_security_check`。

1. `transfer()` 并不调用 `fetch`/`XMLHttpRequest`，而是执行：

   `window.WeixinJSBridge.invoke("finderH5ExtTransfer", n, callback)`。

2. 原生层回调后，前端从 `te.jsapi_resp.resp_json` 取字符串，`JSON.parse` 后再从下划线字段转换为驼峰字段。

因此它确实是网络加载的列表，但请求由 JSBridge 交给原生网络栈，不会作为普通页面 XHR/fetch 出现在 Chromium 的常规网络列表里。

### 当前进程与连接归属

当前 RadiumWMPF（product 1002）根进程为 `WeChatAppEx.exe` PID 7352，作品页 renderer 包括 PID 26856。快照时当前 Radium 进程族没有 TCP 连接；主进程 `Weixin.exe` PID 32760 保持一条 IPv6 远端 443 的 Established 连接。

需要注意：历史上看到的 `WeChatAppEx.exe` PID 59508 到 `112.80.180.89:5000` 的连接，命令行显示其属于另一个 Androws/WmpfRuntime product 3000 的 `flue.mojom.ILinkServiceHost`，不是当前 product 1002 的视频号 profile 列表，不能把该 5000 端口连接当作本接口证据。

### 已提取到的 request

新增工具：`tools/userpage_jsapi_extract.py`。



```
& "C:\Users\ASUS\AppData\Local\Programs\Python\Python314\python.exe" "tools\userpage_jsapi_extract.py"
```

当前从 PID 26856 提取到 30 条原始 `finder_basereq` 请求记录（含重复驻留和历史日志）。请求体稳定包含：



* `finder_basereq.userver_for_h5`、`request_id`、`scene`、`ctx_info`；

* `username`：目标作者 finder username；

* `finder_username`：当前登录用户的 finder username；

* `object_id`：来源 / 当前对象 id；

* 分页请求额外包含 `last_buffer` 和 `direction=0`。

当前样本中分页请求的 `last_buffer` 长度为 120；无游标请求不携带该字段或为空。这与 UIA 分页增长互相印证。

### 是否使用 page/offset/count，能否连续模拟翻页

实际请求没有使用 `page_num`、`page_count`、`offset`、`limit`、`count`、`size` 等字段。对 30 条驻留请求取并集后，顶层字段只有：



* `username`、`finder_username`、`object_id`；

* `last_buffer`；

* 分页请求的 `direction`；

* `finder_basereq`。

`last_buffer` 是服务端返回的不透明 continuation cursor，不是数字页码或 offset。当前样本的 120 字符 base64 游标解码为 90 字节，protobuf 结构中包含内部序号和上一批 feed 的多个 object id；客户端应原样回传，不能把它当作可任意改写的 offset。

分页语义：



1. 首次请求：`last_buffer` 为空；部分新链路会带 `direction=2`。

2. 后续请求：携带上一次响应返回的 `last_buffer`，并带 `direction=0`。

3. 响应返回 `continueFlag` 和新的 `lastBuffer`；`continueFlag=1` 时继续，`continueFlag=0` 时结束。

4. 页大小由服务端 / 原生链路决定，客户端没有可验证的 `count/limit` 参数；私自增加这些字段没有代码依据，未知字段大概率被忽略或导致请求失败。

连续拿全是可行的，但分两条路线：



* **微信 CEF 页面上下文内 / 经由前端模型：可行。** 按 “空游标 → 取响应 `lastBuffer` → 原样回传” 的链路循环，直到 `continueFlag=0`。新 hover 样本已证明无 focus 的 `ScrollIntoView` 可让前端 store 自动执行该循环，并从 15 条静默分页到 442 条。

* **Python 离线 HTTP 复放：当前不可行。** 该请求不是普通 XHR/fetch，而是 `window.WeixinJSBridge.invoke("finderH5ExtTransfer", ...)` 交给原生网络栈；参数包含 `h5AuthToken`、`cgi_cmdid=6624`、scope、request\_id 和原生会话状态。当前没有离线 CGI 客户端或 MM 私有协议密钥，不能只拿 JSON 向 `/cgi-bin/micromsg-bin/pc_finderuserpage` 裸发请求。

### response 可分析到什么程度

前端代码证明响应适配后的关键字段为：



* `data.object`：feed 对象数组；

* `continueFlag`：是否还有下一页；

* `lastBuffer`：下一页游标。

`FlowFeedList` 直接使用 `data.object` 过滤直播类型，并以 `!continueFlag` 判定 `noMore`。

当前仍未在内存中找到稳定、完整、可直接解析的 userpage `resp_json` 全量响应。原因是响应经过原生桥回到 V8 后，对象以 V8 堆对象 / 压缩指针形式驻留；完整数组不会长期以 JSON 字符串保留。blockfile cache 只证明媒体和封面缓存，不缓存该 JSBridge CGI 的完整响应。

结论：



* **request 已经可以本地、免费、只读解析。**

* **response 的字段结构和消费位置已经明确；单条 feed 对象可从堆 / 上报串恢复。**

* **若要自动捕获每一次完整 response，需要在页面上下文内对 JSBridge 或回调做插桩，或继续做 V8 堆对象解析；仅靠普通 DevTools、系统代理或当前 blockfile 不能直接拿到完整响应。**

输出：`work/userpage_jsapi_requests.json`、`work/userpage_raw_contexts.json`、`work/cgi_log_memory.json`。

### 从非 hover 切到 hover 会不会重新拉列表

结论：**正常情况下复用同一个&#x20;**`authorProfileFeedList`**，不会因为界面切换本身再次调用&#x20;**`pc_finderuserpage`**。**

代码证据：



* `AuthorProfileArea` 读取的是当前 feed 对象上的 `authorProfileFeedList`，不是 hover 窗口新建的独立列表。

* 组件 watcher 会调用 `authorProfileFeedList.fetch({initOnly:true})`。

* `FeedList.fetch()` 对 `initOnly` 有短路逻辑：当 `feeds.length > 0` 时直接返回，不进入 `fetchApi`，因此不会调用 `finderUserPage`。

* 只有列表为空、组件首次初始化、后续滚动到接近末尾，或显式 hard refresh 时，才会继续发起网络请求。

这也与父链 / 节点保留实验一致：切到 hover 主要是展示层和层级状态变化，底层 feed 模型及已加载作品数组继续保留。

## 结论



1. 进入 hover 后，原 profile 弹层不是确定性销毁；RawViewWalker 父链证明 `author-profile-area`/`scroll-ctn` 和卡片会保留。

2. UIA 可稳定读取首批卡片的位置、时长、点赞和描述，但不直接给出 oid/URL。

3. 无 focus 的 `ScrollIntoView` 已在 hover 播放器 `author-profile-area` 从 15 条静默分页到 442 条，并在未聚焦、部分遮挡的独立 `page-profile` 从 30 条静默分页到 180 条；完全遮挡、以及屏幕内区域完全遮挡的混合场景均不触发后续分页，早期样本则需要 `SetFocus` 兜底。

4. 作者作品列表通过 `finderH5ExtTransfer` JSBridge 交给原生网络栈加载；没有 page/offset/count 参数，分页依赖服务端返回的 `last_buffer` 游标，离线 Python 裸 HTTP 复放当前不成立。

5. 进入 hover 后，已驻留 / 已上报的 feed 对象可回出完整 20302 URL、decodeKey 和 20350 封面。

6. 本地 blockfile cache 可免费、离线地恢复 profile 卡片封面；20304 的顺序可映射 UIA 卡片序号。

7. `profile_auto_collect.py` 已默认固化无 focus 的 `ScrollItemPattern.ScrollIntoView` 静默分页；下一步通过逐页内存采样闭合 `idx -> oid -> URL`。