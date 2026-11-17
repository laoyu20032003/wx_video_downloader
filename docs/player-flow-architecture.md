# 播放窗口（沉浸连播抽屉）架构与预加载信息探查

> **DeepSeek Harness** · 文档整理与验证
>
> **来源**：豆包本地探索记录（2026-11-17，原文件 `D:\Doubao\wx_video_downloader\docs\player-flow-architecture.md`）。
> 豆包 package/探针不随本仓库提交。
>
> 本文解释播放窗口（沉浸连播抽屉）的列表/预加载/播放器分工。
> 结论：列表和关联在主 renderer store；播放器进程只拿当前条的 url + seed + 明文头；
> 后台/隐藏/非活动播放器会暂停解码，不能靠“多开后台播放器”稳定取明文头。
>
> 与当前 `wx-viewer` 的 hover 8 秒路线互补；不改变“密封 URL 仍需微信在场签发”的边界。

> 2026-11-17，基于视频号前端包 `wxalite28e098851253e34f4777f7ca024236fd`（`main/174/dist/pkg/`）静态 JS 阅读 + 既有内存实证。
> 关联：`association-research.md` §3.2（xplayer 瘦 slave）、`card-url-binding.md`、`non-hover.md` §2A.4/§2B。

## 1. 结论先行：是混合架构，不是「纯上层给流」也不是「播放器自持 list」

用户猜想的两种极端，实证都不完全成立：

| 层 | 归属 | 持有什么 |
|---|---|---|
| 上层列表 store（renderer 前端） | 主页/推荐/作者页/收藏等 feed 列表 | 整条 `feeds[]`、当前索引、补页游标（lastBuffer/sessionBuffer）、每条 feed 的 oid/nonceId/文案/时长/点赞/媒体材料（url/urlToken/decodeKey/spec） |
| 沉浸抽屉 store（renderer 前端） | 播放窗口本身 | 当前条目、连播开关、相关推荐队列；通过 `loadLocalPlaylist` 接收上层列表，自己调推荐 cgi 追加下一批 |
| 原生播放器进程（xplayer / WeixinAppEx 渲染侧） | 瘦 slave | 只拿到**当前这一条**的 url + seed + 前缀缓冲；不持有列表、下一条 id、标题文案，进程内存零命中流标识（既有实证 §3.2） |

一句话：**列表和推荐关系在上层 renderer store 里维护；播放器进程只是当前条的解码/渲染执行者。** 探索价值在上层，播放器进程侧只能拿到当前条的解码缓冲（明文头）。

## 2. 静态证据

### 2.1 列表 store 类（`chunks-common.js`，模块 62188 附近）

- 状态字段：`feeds=[]`、`fetchApi`、`currentFeedIndex`、`fetching`、`buffers={lastBuffer, sessionBuffer}`、`limit=300`。
- 派生：`get currentFeed(){ return this.feeds[this.currentFeedIndex] }`、`hasPrev = index>0`、`hasNext = index<length-1`。
- 翻页：`setCurrentFeedIndex(e)` 在索引到达 `length-3` 时自动 `this.fetch()` 补页；`fetch()` 调 `fetchApi`，响应 `data.object[]` 经 `createFeed` / `new Feed(obj)` 映射后 reset 或 push，回写 `lastBuffer/sessionBuffer`。
- 连播：`goToNextFlowFeed(e)` —— `hasNext` 则 `index+1`，否则按 `goBackWhenEnd` 回卷到 0；切换后上报 `flowChangeFeed`（fromFeedId/toFeedId/索引）。
- 补页接口按列表类型分流：`finderPcFlow`（flow）/ `finderStream`（stream）/ `finderGetRecommend`（推荐）；作者页 `finderUserPage`，收藏/点赞 `finderGetInteractionedFeedList`，会员 `fetchFinderMemberFeedList`。

### 2.2 沉浸抽屉（`670.js` `FlowDrawer` 组件 + `chunks-common.js` 抽屉 store）

- `loadLocalPlaylist(playlist, currentId)`：把上层已有的列表 store 传入，`setCurrentFeedIndex(feeds.findIndex(id===currentId))`，记 `localFlowTab`；`unloadLocalPlaylist()` 退出时卸载。
- 连播开关：`autoPlayNext` + `toggleAutoPlayNext`，持久化到本地 `feedVideoAutoNext`。
- 相关推荐队列：`getRelatedList()` 调 `finderGetRecommend`，入参 `{lastBuffer, objectId, objectNonceId, longitude, latitude, scene=MMFinder_Recommend_PC_Feed, sessionBuffer}`；响应 `data.object[]` 用 `new Feed(obj)` 追加到相关队列 `O.value`，回写 `lastBuffer`。
- 抽屉内其他列表入口：会员作品 `fetchFinderMemberFeedList`、互动列表 `finderGetInteractionedFeedList`、作者主页 `finderUserPage`，均为同一 `object[]` feed 模型。

### 2.3 预下载与播放器 SDK 交接（`store-common.js` 模块 22336 + `chunks-common.js` SDK）

- 缓存记录（`feedCacheInfoMap` / 落 IndexedDB videoCache）：`{createTime, feedId, videoKey, preDownloadedContentLen, videoContentLen, seed: media[0].decodeKey}`。
- `getVideoInfo(feed, flag)`：按 feed 键查缓存 map，过期则清；`getPreDownloadedVideoBuffer(feed)` 经 `lite.file` 打开 `videoKey`，读出前缀 ArrayBuffer，连同 `preDownloadedSeed(=decodeKey)`、`preDownloadedContentLen`、`videoContentLen` 返回。
- 播放器 SDK 选项（`670.js` 构造）：`{url, seed, mediaElement, duration: videoPlayLen, minBufferedTime, maxBufferedTime, cacheConfig, preloadConfig:{preDownloadedBuffer, preloadSeed, preLoadVideoContentLen, onPreloadFailed}}`。
- 解密在 renderer 内 `decrypt-video-core` worker + wasm 完成；前缀缓冲只覆盖前 `X-enclen`（默认 131072）字节，其后明文。

## 3. 预加载的三类信息，分别在哪

| 预加载类型 | 触发/位置 | 携带信息 | 我们能否读到 |
|---|---|---|---|
| 列表补页 | 索引距尾部 3 条，store 自动 `fetch()` | 下一批 `object[]`：oid/nonceId/媒体材料/文案/时长/点赞 | renderer 堆内 feed 对象或 cgi 响应镜像（既有配对链路已部分利用） |
| 流前缀预下载 | `getVideoInfo` 命中后 `lite.file` 写缓存；未命中走 fetch HEAD+Range | 前缀密文 + `seed(decodeKey)` + 已下载长度/总长度 + videoKey | 磁盘 videoCache 分片 + IndexedDB 记录（`videocache_records.json`，方向 1 已接入回表） |
| 相关推荐队列 | 当前条播完/临近尾部，抽屉 `getRelatedList` | 下一批推荐 feed 对象，键为当前条 objectId/nonceId/sessionBuffer/lastBuffer | renderer 堆内相关队列；静态 JS 可见入参/出参结构 |

## 4. 与既有内存实证的对照

- §3.2 已证：xplayer 进程对 `stodownload/encfilekey/finder.video/.mp4` 零命中，标题/文案/对象 id 不走 UIA，绑定关系不落在播放器进程。本次静态阅读与之一致：播放器只接收 SDK 选项里的当前条 url/seed/缓冲。
- 明文 MP4 头必须实际解码后才驻留有限缓存，会被新头挤出；这解释了「hover/播放几秒后内存才有头」，也说明播放器进程侧的可读产物只有当前条解码缓冲，没有列表快照。
- oid ↔ 媒体材料的权威同体位置是 renderer feed 对象（`objectDesc.media[0]`）；密封 URL 镜像在主进程/网络服务记录里。两边配对仍需靠时长/点赞/序号复合锚点，不能按流量出现时间猜。

## 5. 对本项目的含义

1. **上层是主要探索面**：feed 列表、下一条、相关推荐、decodeKey/urlToken 都在 renderer store 与列表 cgi 响应里；播放器进程不值得作为列表/主键来源攻坚。
2. **播放器进程的唯一价值**：当前条解码后的明文头（现有 `dl_engine` 内存头拼接路线在用）；seed 自解密兜底（任务 #20）可在内存头缺失时替代这一环。
3. **下一条不是黑盒**：连播顺序 = 上层 `feeds[]` 索引优先，耗尽后接相关推荐队列；两者都是同一 Feed 模型。但密封流 URL 仍需微信会话在场签发，静态读 JS 不能离线造 `token/basedata/sign/svrbypass`（卡点不变）。

## 6. 未闭环、留待后续

- runtime 下 renderer 堆内抽屉 store 的 `feeds[]` / 相关队列 `O.value` 对象形态尚未直接归因到具体地址；若要在内存里读「当前列表 + 下一条」，需先定位该 store 实例（区别于新闻流卡片 blob）。
- 相关推荐 cgi（`finderGetRecommend` / 5222 相关列表）的请求-响应原文未抓过；入参出参结构来自静态 JS，字段以原始响应体为准（任务 #4）。
- **运行时可达性已确认（2026-11-17）**：抽屉/卡片 DOM 不在主进程 `Weixin.exe` pid 41832 的 Qt 框架窗子树内，而在 `WeChatAppEx.exe` 子进程（实测 pid 47640）子树；UIA 必须从根全树扫描，只在 41832 窗下找会漏。屏幕截图对 MM 表面可能不绘制，但 UIA 树可达，卡片/文案/时长/点赞/右键菜单均可枚举。右键「播放」已可程序化打开抽屉（见 §8.5、`non-hover.md` §2A.6），因此第一项抽屉取样已具备现场条件，尚未执行堆归因。

## 7. 三条进入播放器的路径与关联载体

播放器抽屉本身不造初始对象；三条入口最终都汇聚到 `/feed` 路由 + `goToDetail`，区别只在「整条 Feed 对象是否随会话带过来」。

### 7.1 关联标识与总线机制（静态证据）

- 路由 query 标识：`oid` = Feed `id`（19 位十进制，编码后传入），`nid` = `objectNonceId` 下划线前缀（编码后传入）；另有 `fpid`（来源页）、`foid`（`fpid===feed` 时记为 `relatedFeedId`）、`from_access_id`、`sessionBuffer`、`fromSubPage`、`muted`、`membership`。
- 会话总线：`goToDetail(feed, t)` 先 `bus.set(feed 路由, t.busData ?? {__obj: feed, sessionBuffer: feed.sessionBuffer})`，再路由跳转带 `bus` 键。`bus.get` 命中 `__obj` 时先按 `id` 推入 `feedObjectCacheQueue`，再把 `__obj` 从落盘副本里剥掉。
- 单条材料刷新：当前 feed 挂载后调 `getObjectAsyncLoadInfo()`（`finderBatchGetObjectAsyncLoadInfo`，cmdid 8050）补异步材料；`V.value.push(feed.id, feed)` 按 id 入缓存队列。
- 边界：`tipsInfo.needReplaceObjectInfo` 为真时，总线只带 `sessionBuffer`、**不带 `__obj`**，对象必须重新拉取（提示卡片/替换对象场景）。

### 7.2 三条入口对照

| 入口 | 触发动作 | 关联载体 | 兜底标识 | 初始列表来源 |
|---|---|---|---|---|
| 1. 系统推荐列表 | 首页/推荐流卡片点击 → `goToDetail` | 会话总线带整条 `__obj` Feed；`feedObjectCacheQueue` 按 id 缓存 | `oid`(id)、`nid`(nonceId 前缀)、`sessionBuffer`、`reqIndex` | 首页 flow store 的 `feeds[]`，`loadLocalPlaylist(homeStore, feedId)` |
| 2. 聊天分享 / 外部链接 | 跳转 `/feed?oid=&nid=&fpid=&foid=&from_access_id=` | 冷启动无 `__obj`；按 oid/nid 拉单条对象（8050 或页面 fetch），之后由 `getRelatedList` 补相关队列 | `oid`、`nid`；`fpid/foid/fromAccessId` 仅做来源归因与埋点 | 单条对象 + 相关推荐队列（无本地列表数组） |
| 3. 作者页 Card | 作者页卡片点击，`fromSubPage:"profile"` → 同一 `goToDetail` | 总线带整条 `__obj`；作者页 store 持有该列表 | `oid`、`nid`、`sessionBuffer` | `authorProfileFeedList` store 的 `feeds[]` |

直播/直播回放不走普通 feed 抽屉：`goToDetail` 识别 `liveInfo.replayStatus` / `mediaType===live` 后分别路由 `livereplay` / `live`，query 同样只带 `oid/nid`。

### 7.3 对配对的含义

- **同会话点击（入口 1/3）**：整条 Feed 对象已在 store/总线里，oid ↔ 文案/时长/点赞/媒体材料是同体绑定，权威主键就是 `id`（oid）+ `objectNonceId`；不需要靠流量出现顺序猜。
- **冷分享（入口 2）**：URL 里只有 oid/nid，标题和材料要等服务端响应回来才有；本地在响应被抓到之前，无法离线把 oid 映射到标题（与 non-hover §2B 结论一致）。
- 无论哪条入口，进入抽屉后连播顺序都回到 §2.1/§2.2：本地 `feeds[]` 索引优先，耗尽后接相关推荐队列；播放器进程始终只收当前条。

## 8. 分享入口唤起路线评估与后台单播限制

### 8.1 分享链路携带的静态信息

冷分享/外部链接进入 `/feed` 路由时，URL 上只有少量标识：`oid`(id)、`nid`(objectNonceId 前缀)、`eid`、`req_time`、`fpid`、`foid`、`from_access_id`、`sessionBuffer`、`fromSubPage`、`muted`、`membership`。前端 `/feed` 页挂载（`onMounted → Ie()`）只做两件事：按 oid/nid/eid 重置评论详情；若 `fromSubPage` 属于收藏/点赞/作者页，则加载对应交互列表。**页面本身不按 oid 重新拉取单条 Feed 对象**——同会话进入时对象来自总线 `__obj`，冷启动对象由原生层/分享卡片在打开 webview 前注入或在 MM 会话内解析。

### 8.2 外部按 oid 唤起播放器：静态普查结论

对全包 `WeixinJSBridge.invoke` / `lite.jsapi.invoke` 动作枚举（探针 `tools/probe-bridge-actions.py`）：

- 路由类：`openLiteApp`（按 appId/page/query 打开内部 liteapp，`targetSession` push）、`openUrlWithExtraWebview`（打开 H5/resourceid 页面）。
- 业务类：`sendFinderMessage`、`AddFavorite`、`GetPreloadDataInterval`、`getCommentDetail`、`profile`、`imagePreview`、`openWeApp`、`openWXSearchPage` 等。
- **没有** `playFeed` / `previewByObjectId` / `openFeed` 这类按 objectId 触发播放或取流的 action；`dispatchFinderAction` 已见字面量仅 `AddFavorite`、`GetPreloadDataInterval`（与 §2A.4 普查一致）。
- 前端包内 `weixin://` 仅作内部 `resourceid` host（音乐播放列表等），未发现外部可唤起 feed 播放的 URL scheme。
- 这些桥调用只存在于 renderer 内部；无远程调试端口，外部 Python 无法直接 invoke（既有结论）。

判定：**「拿到 card 信息后由我们按 oid 调起播放器」在前端静态面没有可用入口**；目前唯一实证可行的触发仍是 UIA 点击卡片（DSH 路线）或 hover 激活。即便能在会话内路由到某条 Feed，密封 ready URL 仍需服务端在场签发，离线造不出。

### 8.3 多开窗口与单播互斥（用户观察复核）

- 前端未发现 `pauseOthers`/全局播放注册表这类跨窗口互斥逻辑；暂停发生在两个时机：切换 Feed / 离开抽屉时 `player.pause()`；页面 `visibilitychange` 回到 visible 时再 `play()`（`670.js` @99061 附近）。
- 多个播放窗口可以并存，但隐藏/非活动实例进入暂停态；互斥更可能由原生 webview 生命周期 / 前后台可见性强制，而非 renderer 间共享状态。
- 对下载路线的含义：**后台暂停的实例不会实际解码**，也就不会在内存驻留明文 MP4 头；后台能留存的只有 VC 前缀密文分片 + seed（decodeKey）记录，对应方向 1 留存链路与 §2.3 的 ISAAC64 自解密兜底。指望「多开后台播放器轮流解码出明文头」与单播暂停行为冲突。

### 8.4 未闭环（待 runtime 实证）

- 同时打开两个 Feed 播放窗口，核对两个 renderer 实例的播放状态/可见性与暂停来源（前端 visibility 回调 vs 原生 webview 生命周期），确认互斥强制层。
- 冷分享对象的注入点：原生分享卡片消息体、还是 webview 初始化参数；需要抓一次分享拉起的原始入口数据（任务 #4 范围）。

### 8.5 程序化触发与「后台不打扰」可行性（2026-11-17）

右键「播放」触发链已实测打通（细节见 `non-hover.md` §2A.6）：UIA 根树枚举 `click-box`/`prev-i` 卡片 → 全局鼠标右键 → 根树扫 `context-menu`（AppEx 子进程）→ 文本定位「播放」→ 矩形中心左键 → 打开沉浸抽屉（出现跨视口 `video-player` 层）。在此基础上，「能否在窗口后台/下层状态下触发且不打扰用户」分两层判定：

**① 触发动作投递（是否需要前台/焦点）**

| 投递方式 | 是否抢前台/移动鼠标 | 后台可行性 |
|---|---|---|
| 全局输入（`SetCursorPos` + `mouse_event`/SendInput，本次实测所用） | 是：目标须在光标下，且消息携带焦点/前台切换，会打断用户当前操作 | 不满足「不打扰」 |
| `PostMessage` 直投卡片子窗口句柄（`WM_RBUTTONDOWN/UP`、左键按下/抬起） | 理论上不移动光标、不抢焦点 | **未验证**：CEF/内嵌 webview 在窗口被遮挡、失焦状态下是否处理已投递的窗口消息，静态读码不能保证；需现场对照 |

**② 后台是否真正起播解码（下载真正依赖的一层）**

- 静态推断（§8.3）：隐藏/非活动 webview 进入暂停态，暂停发生在切 Feed、离开抽屉、`visibilitychange` 回不可见；后台暂停实例不实际解码，内存不驻留明文 MP4 头，后台只留 VC 前缀密文分片 + seed（decodeKey）记录。
- 该推断**尚未现场实证**（属 §8.4 双窗口/后台互斥待办）。计划中的对照测试：前台开一条抽屉静置 5s，扫明文头 + 记 xplayer/renderer CPU；再遮挡或最小化微信静置 5s，同样扫头、看 CPU 是否回落，以此判定后台到底解不解码。
- 对下载路线的含义：即便后台能把抽屉点开，若后台不解码，现有内存明文头拼接路线仍落空；密封 ready URL 也需会话在场签发。**指望多开/挂后台轮流起播取流，与单播暂停行为冲突**；要明文头，对应 webview 必须处于活动/可见状态。
- 边界：seed 自解密兜底（任务 #20）不依赖明文头，但前提仍是该前缀密文 + seed 记录已落 VC/IndexedDB；后台未预取的卡片同样没有这份材料。
