# 播放窗口（沉浸连播抽屉）架构与预加载信息探查

> **DeepSeek Harness** · 文档整理与验证
>
> **来源**：豆包本地探索记录（2026-11-18 更新，原文件 `D:\Doubao\wx_video_downloader\docs\player-flow-architecture.md`）。
> 豆包 package/探针不随本仓库提交。
>
> 本次新增重点：
> - 8.6 聊天短链真实点击现场；9 player feed dump；10 聊天转发卡片 XML。
> - `b-feed-extract` 双编码抽出 91 条 feed（oid/desc/url）；`b-player-dump` 用 UIA 进度/文案回表。
> - 实测当前条回表会出现 `matched` 也会出现 `unmatched`；feed/事件都是某一刻快照，不能当实时指针，当前 oid 尚不能稳定拿到。
> - 聊天卡片 XML 自带 oid + 完整 20302 URL，但只覆盖转发卡片，不是作者主页列表，也没有 decodeKey。

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

**原生分享卡片的生成方式（2026-11-17 静态普查）**：聊天里能直接拉起原生播放器的 finder 卡片，不是由分享链接生成的，而是由抽屉/流 store 里的整条 Feed 对象经桥动作 `sendFinderMessage`（`appid:"finderFeed"`）交给原生层写进会话。序列化器（chunks-common 模块 56590 `l`）字段：`objectId=e.id(oid)`、`objectNonceId`、`feedType=mediaType`、`nickname/username/avatar`、`desc`、`mediaCount`、`localId:"0"`、`mediaList=media.map(...)`、`authInfo`、`link`。即卡片锚点主键仍是 oid + nonceId，材料随卡片同体携带；该桥调用只存在于 renderer 内部，无 CDP，外部 Python 无法代发。`sendFinderMessage` 另一处用于「问小微」转发给助手，同样基于当前 `flowCurrentFeed`。
**实测结果（2026-11-18，用户亲测）**：短链接贴在聊天里点击，**确实拉起了独立的连续播放窗口（原生沉浸播放器）**，并非只开 H5 preview 页。即 MM 原生层识别该链接后在打开 H5 前拦截、路由到 finder 播放器（对应 §7.2 入口 2：聊天分享/外部链接冷启动）。待补抓：点击落地时 `/feed` 路由的 query（oid/nid/eid/exportId/shortUri 各取到哪个）、renderer store 里冷启动对象由原生层注入还是会话内解析；以及 22299 返回的 `feedH5Url` 是否就是 `weixin.qq.com/sph/<shortUri>` 短链本身（任务 #4）。

### 8.2 外部按 oid 唤起播放器：静态普查结论

对全包 `WeixinJSBridge.invoke` / `lite.jsapi.invoke` 动作枚举（探针 `tools/probe-bridge-actions.py`）：

- 路由类：`openLiteApp`（按 appId/page/query 打开内部 liteapp，`targetSession` push）、`openUrlWithExtraWebview`（打开 H5/resourceid 页面）。
- 业务类：`sendFinderMessage`、`AddFavorite`、`GetPreloadDataInterval`、`getCommentDetail`、`profile`、`imagePreview`、`openWeApp`、`openWXSearchPage` 等。
- **没有** `playFeed` / `previewByObjectId` / `openFeed` 这类按 objectId 触发播放或取流的 action；`dispatchFinderAction` 已见字面量仅 `AddFavorite`、`GetPreloadDataInterval`（与 §2A.4 普查一致）。
- 前端包内 `weixin://` 仅作内部 `resourceid` host（音乐播放列表等），未发现外部可唤起 feed 播放的 URL scheme。
- 这些桥调用只存在于 renderer 内部；无远程调试端口，外部 Python 无法直接 invoke（既有结论）。

判定：**「拿到 card 信息后由我们按 oid 调起播放器」在前端静态面没有可用入口**；目前唯一实证可行的触发仍是 UIA 点击卡片（DSH 路线）或 hover 激活。即便能在会话内路由到某条 Feed，密封 ready URL 仍需服务端在场签发，离线造不出。

**短链/scheme 唤起路径（2026-11-18 静态普查 + 用户实测）**：

- 实测：短链接贴在聊天里点击，能拉起独立连续播放窗口（原生沉浸播放器），MM 原生层在打开 H5 前识别并拦截路由。
- 预览 H5（`work/preview-js/`）里有两条交给原生播放器的通道：
  - 桥动作 `openFinderView`，`extInfo` JSON：`{action:"openFinderFeed", feedID: dynamicExportId||eid||ft(id), notGetReleatedList:1, commentScene,...}`；
  - OS scheme：`weixin://biz/finder/openFinderFeed/<encodeURIComponent("exportId=<exportId>&actionType=<h>&commentScene=...")>`；另有 `openFinderProfile` / `openFinderLive` 同族。
- 注册表：`HKCU\Software\Classes\weixin` 与 `xweixin` 的 `shell\open\command` 均为 `C:\Program Files\Tencent\Weixin\Weixin.exe "%1"`，即 scheme 可由外部 `Start-Process` 交给 Weixin.exe，不经过聊天 UI。
- **scheme 载荷锚点是 exportId（dynamicExportId/eid），不是 oid**；oid 只在桥 `openFinderView` 的 `feedID` 回退链 `ft(id)` 里出现，`ft` 转换语义未还原。28e MM finder 包内没有 oid→scheme/短链的本地拼装，列表模型也不下发 exportId/shortUri。
- 待实证：① 外部直接 `Start-Process` 一个合法 `weixin://biz/finder/openFinderFeed/...` 是否被 Weixin.exe 接受并开窗（而非只在页内 `<a>.click()` 生效）；② 22299 响应里是否同时带回 exportId/dynamicExportId；③ 冷启动开窗后 `/feed` query 与 renderer store 对象的锚点字段。
- **① 阶段性实测（2026-11-18 00:06）**：用留存样本 `dynamicExportId=export/UzFf...`（expiredTime 1794917771，已过期约 3.8h）按 `exportId=...&commentScene=39&entryScene=64&entryCardType=48` 编码构造 scheme，外部 `Start-Process` 交给 Weixin.exe。结果：**scheme 被接收**——新起两个 `WeChatAppEx.exe --type=renderer`（product-id 1002，render-type 7，renderer-client-id 22/23）；但无可见顶层窗口（样本过期，错误/空 webview 未呈现）。scheme 能否对有效 exportId 开出可见播放器，需用新鲜链接重测。构造脚本 `tools/probe-scheme-build.py`，URI 留存 `work/scheme_test.txt`，前后窗口快照 `work/scheme_before.txt` / `scheme_after.txt`。
- **① 新鲜样本复测（2026-11-18 00:10）**：短链 `https://weixin.qq.com/sph/AvjP3q1JQP`（作者「杠京-北京杠爷」，匿名 `get_feed_info` 取回有效 `dynamicExportId=export/UzFfBgAAxICmYDh4...`，expiredTime 1794939021，约 2h 有效；匿名响应仍无 oid/流地址）。重建 scheme 外部 `Start-Process`：
  - 新起 renderer pid 50292（product-id 1002，render-type 7，client-id 25），但**无可见顶层播放窗口**；UIA 全树只有既有作者主页网格（434 条原创、prev-i 卡片），无 `video-player` 层、无抽屉评论项。
  - 扫 50292 内存：只有 `/web/pages/feed` 路由模板串和 `openFinderView` 桥名（公共 bundle 代码），**无 exportId/oid/文案落地**；内存中出现原生报错串 `APIGetBrowserView is nullptr!`、`session is nullptr`。
  - 判定：外部 scheme 唤起能拉起 finder renderer 进程，但**没能建立浏览器视图/会话**，feed 对象未注入；聊天内点击之所以能开窗，走的是会话内既有视图/桥上下文，外部 scheme 复放在原生会话层被卡住。脚本 `tools/probe-fresh-link.py`（匿名解析+建 scheme）、`tools/probe-renderer-route.py`（renderer 内存路由痕迹）；产物 `work/sph_fresh_raw.json`、`work/scheme_fresh.txt`、`work/uia_scheme_fresh.txt`、`work/scheme_fresh_before/after.txt`。
  - 待办：抓一次聊天内真实点击的现场，对比它走的是 `openFinderView` 桥还是 scheme、挂在哪个既有 browser view、注入对象带哪些字段（任务 #4）。

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

### 8.6 聊天内真实点击现场（2026-11-18 00:28 实测，任务 #4）

触发方式：用户在微信聊天里点击唯一一条短链，原生连续播放抽屉直接弹出（右上角，标题栏「视频号」）。与 §8.2 外部 scheme 复测对照：**会话内点击能开窗，外部 scheme 卡在 `APIGetBrowserView/session nullptr`**，差别在于前者复用既有会话视图 + 桥上下文。

**现场进程/窗口（PID 重启后须重枚举）**

- 主进程 `Weixin.exe` pid 41832（Qt 主窗）；`WeChatAppEx.exe` 浏览器进程 pid 47640，下挂两个 Chrome widget：旧大 webview `10423776` (156,156,1596,909)，播放器窗 `11077882` (1170,224,1859,1031)。
- 点击时新起 renderer：pid 18784、49356（`--wmpf-render-type=7`）；既有 45276/46992/52784/42520。store 列表落在 18784。

**播放器 UIA 暴露整条推荐列表（hwnd 11077882，共 113 后代）**

每行一个 `feed-video video-js` 节点 + 标题(50020) + 头像/账号(50006/50020) + 操作项计数；纵向顺序即播放顺序（ended → playing → 预加载 next）：

| 序 | 播放态 | oid | 账号 | 标题/文案 | 计数（喜欢/分享/推荐/评论） |
|---|---|---|---|---|---|
| 1 | vjs-ended | `1503937447215313992` | 杠京-北京杠爷 | 新到货的机器人朋友！#公园健身 #核心力量 | 1806 / 840 / 850 / 155 |
| 2 | vjs-playing | `1505584850762511390` | 拾光-留声 | 《我爱五指山，我爱万泉河》作词:郑南 作曲:刘长安 演唱:牟炫甫 | 8178 / 8681 / 5590 / 2427 |
| 3 | vjs-paused（下一条） | `1505404054950557090` | 七哥档案 | 【第二集】自认为天衣无缝 三天就暴露身份 \| 廖永雄伏法记② #故事#睡前故事#真实事件#奇闻奇事#社会百态 | 4.9万 / 2.5万 / 1.7万 / 2075 |

- **UIA 节点不带 oid / exportId / nonceId**，只有文案、矩形、计数；身份主键在 renderer store 堆里，需内存侧按文案/顺序回表。三行 oid 均已用堆上下文回表（见下）。

**内存侧绑定（pid 18784）**

- store 堆内 25 条 `export/UzFf...` exportId 与若干 19 位 oid；点击的第 1 条已对上：堆内日志串 `[更新 feed]开始重拉 feed 1503937447215313992` 紧邻文案「新到货的机器人朋友！」→ **点击视频 oid = `1503937447215313992`**（作者杠爷）。
- 桥调用构造从 pid 52784 utf-16 JS 片段还原：
  `l===P.DEST_TYPE.CHANNELS?function(e,t){var n={action:"openFinderFeed",feedID:e.extBackComm.channels_info.id,nonceID:e.extBackComm.channels_info.nonce_id,f...}` … `return E.openFinderViewPromise({extInfo:n})}`。
  即：聊天 channels 分享卡片 → 桥 `openFinderView`，`extInfo={action:"openFinderFeed", feedID: channels_info.id(oid), nonceID: channels_info.nonce_id, ...}`。
- renderer 堆内**不留存** `sph/` 短链串（短链在注入前已解析成 oid/exportId）；**未见** media URL / decodeKey / seed（流仍交原生 xplayer/主进程，与既有结论一致）；exportId 以独立 V8 字符串存放，与字段标签不相邻，按标签正则取不到。

**nonceId（objectNonceId）回表（2026-11-18 补，pid 18784 堆探针）**

- 前端模型：`this.id=e.id, this.objectNonceId=e.objectNonceId||""`；形态 `<nonce前缀>_<type>_<scene>_..._<session uuid>`；路由取 `split("_")[0]` 后经 `G()` 编码成 query 的 `nid`。
- 三条 oid 回表结果（完整值见 `work/player_chat_bind.json`）：

| 序 | oid | nonce 前缀 | 完整 objectNonceId | 置信度 |
|---|---|---|---|---|
| 1 | `1503937447215313992` | `9490651182817725983` | `9490651182817725983_0_141_0_0` | 中（短形态，无会话 uuid；scene 段 0，聊天注入源） |
| 2 | `1505584850762511390` | `17474338491405244932` | `17474338491405244932_4_141_84_64_1794932788074740_a3cb3988-e2a3-11f1-b038-8f33ead`（uuid 尾被堆窗口截断） | 高 |
| 3 | `1505404054950557090` | `5189434392828033035` | `5189434392828033035_4_141_84_64_1794932788074740_a3cb3988-e2a3-11f1-b038-8f33eada5ac9` | 高 |

- 第 2/3 条共享同一会话 uuid `a3cb3988-e2a3-11f1-b038-8f33eada5ac9`（同一抽屉推荐队列）。
- **原生解码记录不带 nonce**：`probe-nonce-decode.py` 解邻近 base64 JSON（ele_info/session_buffer）只含 `object_id`，无 `object_nonce_id`/`objectNonceId` 字段；nonce 只存在于 V8 JS 堆。V8 属性名与值分存，按堆邻近度配对，同队列兄弟共享 uuid 段。
- **`G()` 已还原并实证（2026-11-18）**：webpack 模块 57569（store-common.js）导出 `G`(编码 `a`) / `n`(解码 `c`)；大整数模块 45021 为 64 位 low/high BN，`toBytes()` 无参走 BE、固定 8 字节；base64 字符表标准 `A-Za-z0-9+/`；模块 19411 `_j`/`hN` 做 base64url 互转。
  - 编码：十进制串 → int → 8 字节大端 → 标准 base64 → `+`→`-`、`/`→`_` → 去填充 `=`。
  - 解码：`-`→`+`、`_`→`/` → 补 `=` 到 4 倍数 → base64 解码 → 8 字节大端 → 十进制串。
  - 实证：pid 46992 堆内 3 条已求值路由（6 个 oid/nid 令牌）回算全部 MATCH，样本见 `work/route_token_samples.json`；Python 实现 `tools/oid_codec.py`（`encode_id`/`decode_id`）。
  - 注意：该变换只服务前端 `/feed` 路由 query；**不等于** scheme/短链锚点，scheme 载荷仍是 exportId（见 §8.3）。

**待闭环**

- 抓一次 feed cgi 原始响应，确认 exportId ↔ oid ↔ 标题/nonceId 映射（任务 #4）。
- 区分「原生分享卡片点击」与「纯 H5 短链点击」是否走同一条 `openFinderView/openFinderFeed` 桥。

**本次产物**：`tools/probe-feed-anchor.py`（路由/oid/exportId/短链/流地址/seed 锚点扫描）、`tools/probe-feed-context.py`（按中文文案抓周边堆上下文回表 oid）、`tools/probe-uia-hwnd.py`（按句柄导 UIA）、`tools/probe-nonce-mem.py`（按 oid/标签抓堆内 nonce 形态串）、`tools/probe-nonce-decode.py`（解 base64 JSON 验证原生记录是否带 nonce）、`tools/oid_codec.py`（G/n 编解码 Python 实现）、`tools/probe-g-module.py`（webpack 导出定位）、`tools/probe-route-token.py`（堆内已求值路由令牌提取解码）；`work/feed_anchor_now.json`、`work/feed_context.txt`、`work/feed_context2.txt`、`work/player_uia.txt`、`work/player_now.png`、`work/player_chat_bind.json`、`work/nonce_mem.json`、`work/nonce_decode.json`、`work/route_token_samples.json`。

## 9. 播放器 feeds 列表 + 当前 feed dump（路线 B 落地版，2026-11-18）

> 本节为可运行 dump 能力；**xplayer 深层反查（从解码句柄反推当前 oid）本阶段挂起**，见 §9.4。

### 9.1 工具与产物

- `tools/b-feed-extract.py`：从 WeChatAppEx renderer 堆抽 feed JSON 块，正则抽 `id(oid)/nickname/description/media url`，落 `work/feed_extract.json`；**合并写回**（只补全/追加，不覆盖旧缓存）。
- `tools/b-player-dump.py`：在 feed 表基础上枚举微信顶层播放窗 UIA，锚定当前条目并分组，落 `work/player_dump.json`。用法 `python tools/b-player-dump.py [--scan]`（默认复用 `feed_extract.json`；`--scan` 重扫堆并合并）。

### 9.2 feeds 列表来源

- feed 对象在 renderer 堆里以两种镜像并存：**u8（UTF-8）** 与 **u16（UTF-16LE）**；扫描必须两种编码都解码，只扫 u8 会漏掉大部分块（实测只命中 1 条 → 双编码后 91 条）。
- 块外层包装两种：列表响应 `{"BaseResponse":...,"object":[{"id":...},...]}`、单条响应 `{"BaseResponse":...,"object":{"id":...}}`；正则按 `"id":"<oid>","nickname":"...","object_desc":{"description":"..."` 匹配，不依赖前导 `{`。
- 分组判据：同一堆内按 `nickname` 聚簇——单一作者 ≥3 条归**主页列表**，多作者混合归**推荐流**。
- 块内 `media[0].url` 即 stodownload 流地址；`feed_extract.json` 每条含 `oid/nickname/desc/url/pids`。

### 9.3 当前 feed 判定（UIA 实时锚点）

堆块是缓存集合（历史/预载/残留混合，无"当前"标记），事件流又丢事件、混窗口、不记进度（见 `association-research.md` §16.52）。当前条目只能从**实时 UI 树**锚定：

1. 顶层播放窗 UIA 文本序列里，第一条匹配 `^\d{1,2}:\d{2} / \d{1,2}:\d{2}$` 的进度文本为当前条进度；相邻卡片的进度在其后，已排除。
2. 进度后第一条长度 >6 的长文本 = 主文案；后续命中 feed 表 nickname 的文本 = 作者。
3. 回表配对：先按作者缩簇，再按文案前缀 12 字精确匹配，其次包含匹配；`matched` 取值 `desc-prefix / desc-contains / unmatched / no-progress`。
4. 主页网格窗（无进度文本）判 `no-progress`，不当播放窗。

### 9.4 局限与挂起声明

- **缓存波动**：堆块随播放演进被回收/换页，当前刚切到的条目可能尚未入堆或已被挤出，回表 `unmatched`；此时 dump 仍保留 UIA 进度/主文案/作者供人工核对，不猜 oid。
- **进度活性未采样**：本轮只取单次进度文本，未做二次采样判断播放中/暂停/播完；`x:xx / x:xx`（当前=总时长）即播完暂停态。
- **多窗口归属**：两个播放窗的 feed 块可能混在同一 renderer 堆，分组靠 nickname 聚簇 + UIA 锚点；窗口↔renderer pid 的稳定绑定尚未固化。
- **xplayer 挂起**：xplayer 进程是瘦 slave，只收当前条 url/seed/缓冲，不持列表与下一条 id（§1、§3.2）；从其解码句柄反推当前 feed oid 的深层反查本阶段**挂起**，不在本轮 dump 范围。
- 事件流（`flowChangeFeed`/toFeedId/toFeedIndex）仅作辅助旁证，不能单独作为当前条目判据。

### 9.5 2026-11-20 复验：当前条仍可能 unmatched

当前播放窗：

```text
标题：耗时两年，我们的欧式木屋终于建成了…
作者：我是木子夫人
点赞：4.2万
```

运行：

```text
python tools/b-player-dump.py --scan
→ feeds 224
→ pid=26232 progress=None
→ match=no-progress-unmatched
→ oid=None
```

feed 表里有该账号的其他视频，但没有当前标题。说明：

- 当前标题不在本次 renderer 堆快照；
- 无进度文本时，`标题+作者` 回表同样失败；
- `b-player-dump.py` 只能作为辅助 dump，不能保证当前 oid；
- 切条仍不能依赖它。

## 10. 聊天转发卡片消息体形态与唤起路径（2026-11-18 实证）
### 10.1 两种进会话的形态对照

| 维度 | 原生转发卡片（带播放按钮的图片卡） | 纯短链消息 |
|---|---|---|
| 消息体内容 | 自包含对象：oid + nonceId + 文案 + 作者 + 头像 + 封面/缩略图 + 原画流地址 | 仅一个 URL 字符串 `https://weixin.qq.com/sph/<shortUri>` |
| 本地序列化（主进程内存镜像） | `<appmsg>` XML 包裹 `<finderFeed>` 子元素（§10.2） | 纯文本链接；服务端回包才带 `object_id` + `feed_h5_url` |
| 身份主键 | `objectId`(oid) 与 `objectNonceId` 同体 | 只有 shortUri；oid/nonceId 需服务端解析后才有 |
| 材料 | 封面 20304 / 缩略图 20350 / 原画 20302 三档 URL 同体 | 无 |
| 点击唤起 | 读消息体直接开抽屉（§10.3 路径 A） | 先拦截解析短链、再拉对象（路径 B） |

### 10.2 卡片 XML 结构（主进程 41832 内存，`work/card_msg_feeds.json`，11 条）

外层是微信消息 XML：`<msg> … <appmsg> … <appattach> … <finderFeed>…</finderFeed> … </appattach> … <fromusername>…</fromusername><appinfo>…</appinfo> </appmsg> </msg>`。内层 `<finderFeed>` 自包含字段：

```xml
<finderFeed>
  <objectId><![CDATA[15045243550007823056]]></objectId>   <!-- oid，19 位 -->
  <feedType>4</feedType>                                  <!-- 4=视频 -->
  <nickname>杠京-北京杠爷</nickname>
  <avatar>https://wx.qlogo.cn/finderhead/…</avatar>
  <username>v2_060000231003…@finder</username>
  <desc>今天是大爷专场，带领爷爷们用宫廷盘杠中的动作…</desc>
  <mediaCount>1</mediaCount>
  <objectNonceId>13381970339453068488_0_141_2_0_5217949285221794_b502e12e-…</objectNonceId>
  <mediaList>
    <media>
      <url>…/20302/stodownload?encfilekey=6xyk…&amp;m=b6de6fa8…&amp;uzid=7a1ac</url>   <!-- 原画 -->
      <coverUrl>…/20304/stodownload?encfilekey=2fG3…&amp;m=03bbf948…</coverUrl>      <!-- 封面 -->
      <thumbUrl>…/20350/stodownload?encfilekey=2fG3…&amp;m=2e907896…</thumbUrl>      <!-- 缩略图 -->
      <width>1080</width><height>1920</height>
    </media>
  </mediaList>
</finderFeed>
```

- 标签值用 `<![CDATA[…]]>` 包裹，解析前需剥 CDATA；URL 内 `&` 转义为 `&amp;`，先反转义再取 query。
- 实证 11 条均 `feedType=4`；`objectId`(oid) 与 `objectNonceId` 同体，第一条 oid `15045243550007823056` 与 renderer feed 表一致。
- 桥序列化（前端 `sendFinderMessage`，§8.1）字段与 XML 对应：`objectId=e.id`、`objectNonceId`、`feedType=mediaType`、`nickname/username/avatar`、`desc`、`mediaCount`、`mediaList`、`authInfo`、`link`。

### 10.3 唤起播放器路径对比

**路径 A · 原生卡片（短）**
1. 点击卡片 → 原生层直接读消息体 `finderFeed` / `extBackComm.channels_info`（已带 `id(oid)`、`nonce_id`、材料）。
2. 桥 `openFinderView`，`extInfo={action:"openFinderFeed", feedID, nonceID, notGetReleatedList:1, …}`；`feedID` 优先 exportId，回退 oid（前端 47640 `case "openFinderFeed"`：`feedID→eid=`、`nonceID→nid=`，再 `openUrlWithExtraWebview` 开 `/web/pages/feed`）。
3. 会话总线带整条 `__obj` Feed 注入抽屉，直接播放；无需短链解析、无需现场拉对象。

**路径 B · 纯短链（长）**
1. 点击链接 → MM 原生层拦截识别 `sph/<shortUri>`。
2. 短链交服务端解析，换 `object_id`/exportId/对象；冷启动无 `__obj`。
3. 进 `/feed` 页后按 oid/nid 拉单条对象，再由 `getRelatedList` 补相关推荐队列。
- 外部 `Start-Process` scheme 复放在原生会话层卡住（`APIGetBrowserView/session nullptr`，§8.2）；会话内点击之所以能开窗，复用的是既有视图 + 桥上下文。

**为什么卡片路径短**：卡片是**对象消息**，身份与材料在发送时就随消息落库；短链是**引用消息**，只留一个可解析指针，对象要在打开时现取。

### 10.4 工具与产物

- `tools/probe-card-msg.py`：扫主进程/appex 内存关键字（`<finderFeed>`/`channels_info`/`extBackComm`/`openFinderFeed`/`objectNonceId`/`sph/`/`objectId`）命中计数 + 上下文样本。
- `tools/mem-feed.py --pid 41832 --out work/card_msg_feeds.json`：按 `<finderFeed>…</finderFeed>` 标签边界解析，抽 `objectId/feedType/nickname/desc/objectNonceId/username/avatar/media(url/coverUrl/thumbUrl 的 encfilekey/token/m/uzid/尺寸)`。

### 10.5 局限

- 卡片里的原画 `url` 仍是密封 `stodownload`，**XML 不带 decodeKey(seed)**；解密仍需取流上报补 seed（§2.3、任务 #20），不能凭卡片 URL 直接落盘明文。
- 卡片消息落库为加密 SQLite（pysqlcipher3 未装，本轮未破）；上述 XML 是主进程内存镜像，不代表磁盘消息体字节序。
- 内存卡片是历史转发残留，不随作者主页实时列表刷新（§14.2 负向结论）；本轮 11 条含跨会话/广告混合样本。
