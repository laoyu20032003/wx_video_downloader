> **来源与状态**
>
> 本文导入自豆包的本地调研记录（原文件 `D:\Doubao\wx_video_downloader\docs\association-research.md`），保留当时的时间、PID、工具路径和失败方向，作为“为什么这样设计”的原始证据。
>
> 豆包的完整 package/工具不随本仓库提交，仅本地保留；当前落地实现以
> [card-url-binding.md](card-url-binding.md) 和 [../viewer/README.md](../viewer/README.md) 为准。
> 文中旧工具名（`tools/main-pair.py`、`tools/mem-render.py`、`wx-viewer.py`）对应本仓库的
> `viewer/main_pairs.py`、`viewer/mem_render.py`、`viewer/wx_viewer.py`。
# 标题 ↔ 视频流 关联关系排查记录

更新：2026-11-16
适用：微信 4.2.0.13 / Windows / liteapp（RadiumWMPF）
目的：解决"下载文件与视频信息（标题/文案/作者）不能准确对应"的问题。

> 配套专题：`docs/card-url-binding.md` —— UIA 卡片 ↔ oid ↔ 流 URL 配对链路、主键判定、对齐算法与样例的结构化说明。

## 1. 背景与假设

- 早期按"流量出现时间/顺序"把 URL 对应到窗口当前视频，经常错配：视频流常在播放上一条时预加载完成，按当前流量猜会落到下一条。
- 工作假设：关联关系由上层微信程序维护，下层（抓包/内存扫描）不能猜；应沿"播放器实例 ↔ 其绑定的流（id/url/指针）"这条上层链路找权威对照。
- 本轮目标：逐层排查上层信息源里是否存在可直接读取的"标题 ↔ 流 id/url"对照。

## 2. 进程拓扑（本轮在线实测，PID 为快照，重启后以命令行 `--type` 为准）

| 角色 | 判定依据 | 本轮 PID |
|---|---|---|
| 主进程 Qt 窗口 | Weixin.exe，无 --type | 40512 |
| CEF 浏览器主进程 | WeChatAppEx.exe，无 --type | 40116 |
| 网络服务 | `--utility-sub-type=network.mojom.NetworkService` | 26600 |
| GPU | `--type=gpu` | 41152 |
| link 服务 | `--utility-sub-type=flue.mojom.ILinkServiceHost` | 28852 |
| 专用播放器 | Weixin.exe `--type=xplayer` | 39292 |
| renderer ×6 | `--type=renderer`（wmpf-render-type 4/6/7） | 11384 / 26772 / 14456 / 31312 / 2376 / 30060 |
| 其它 | wxocr 36760 / wxutility 40876 / wxpublic 14812 | — |

## 3. 各层实测持有内容

### 3.1 UIA（UI 自动化树）——不可读
- 转储两棵顶层窗口整树（`tools/uia-dump.ps1`，输出 `work/uia_dump_*.txt/.json`）。
- CEF 窗口只暴露浏览器外壳（标签页/最小化/最大化/关闭按钮），`BrowserContentsContainerView` 内容区无任何子元素。
- Qt 主窗口只有 `MMUIRenderSubWindowHW` 渲染子窗。
- 视频标题、文案、播放器控件、对象 id 均未走 UIA 暴露。
- 进程未开远程调试端口：无监听调试端口，命令行无 `--remote-debugging-port`。

### 3.2 xplayer 专用播放器进程（39292）——瘦 slave
- 44 个可读区域、约 0.9MB。
- 对 `stodownload` / `encfilekey` / `finder.video` / `:///.mp4` / `xplayer` / `pipe` 零命中，仅命中插件路径串。
- 结论：播放器经句柄/IPC 接收流，自身不保留可解析的流标识（URL/键/标题都不在本进程）。
- 对用户假设的判定：**"播放器进程里能直接读到它绑定的流 id/url"不成立**；绑定关系不落在播放器进程内存。

### 3.3 网络服务（26600）与 renderer（26772 / 31312）——只持有请求/响应记录镜像
- 完整 `stodownload` URL 与 DNS/传输日志在网络服务；renderer 26772/31312 也缓存了 URL 记录。
- 记录形态：HTTP 请求/响应头缓存（Accept、cookie、Range、TransportInfo、content-type=video/mp4、serverip 等），URL 前带 19 位十进制记录 id（如 `14874878067209935253`）。
- 记录相邻处没有干净中文标题；UTF-16 邻近串多为字节交换的 ASCII 头（误报成"中文"），判读时需过滤。
- 主进程 40512 内存里也镜像了同样的 URL 记录（命中地址 `0x1ec00c5a037` 等），同样无相邻标题。

### 3.4 renderer 内存里的模型 JSON
- 11384 内找到序列化卡片模型 JSON blob（新闻流实证），同对象含 `RecID` / `CardId` / 标题文案：
  - 样例：`{"type":0,"update_time_wording":"","ui_version":2,"report_info":{"Pos":0,"RecID":1794801885,...,"CardId":"pcnew...`
  - 邻近 UTF-16 干净中文："国乒全军覆没34岁方博夺冠"等。
- 证明 renderer 堆确实会以 JSON 序列化对象持有"id ↔ 标题"同对象。
- 视频号等价模型 blob 尚未在持有 `stodownload` 的 renderer 里干净定位：
  - 第一轮粗提取命中的多为 V8/对象堆二进制（字节交换 ASCII、环境变量、DLL 路径、HEVC Coding、`class std::tuple`、`owl::v9::ioc::container` 符号）。
  - 改进后的定位器（`tools/mem-json.py`，只认 ASCII `{"` + JSON 键/UTF-8 中文）在 6 个 renderer 内，唯一干净 JSON 是 11384 的聊天消息日志 blob（`{"func":"log","params":{"msg":"收到新消息 ..."}}`），不是视频号卡片模型。
- 推测：视频号模型要么以原生 protobuf/结构化对象持有（非 ASCII JSON），要么 V8 内部 UTF-16 字符串未与 ASCII URL 记录相邻。

## 4. 已验证为死路的方向

| 方向 | 实证结论 |
|---|---|
| 成品 MP4 元数据 | 11 个 `work/cand_*.mp4` 解析 box 树，仅 ftyp/moov/free/mdat；udta/meta/ilst 只有 ©too 编码器标签，无 ©nam、作者轨、attached_pic 封面轨；内存头 dump 扫不到可读中文。标题无法从成品文件恢复。 |
| 视频 URL 参数 | 参数仅 encfilekey/bizid/idx/m/uzid/token/basedata/sign/extg/svrbypass/svrnonce/taskid/fexam/X-snsvideoflag；basedata 解码为 protobuf 设备/流标识（xWT113 等），无标题、无视频标题 id。573 条 stodownload 中仅 258 条带 `m=`。 |
| 本地落盘数据库/缓存 | `C:\Users\ASUS\Documents\xwechat_files` 两账号目录；全部业务 `.db` 为 SQLCipher 加密（sqlite3 打开报 file is not a database），仅 `all_users\login\key_info.db` 明文。遍历 17309 个文件，已知 `m=`、encfilekey、stodownload 子串零命中。msg/ 3.2GB 为按月/哈希分目录的聊天媒体 .dat，非视频号 feed 缓存。 |
| URL 级 exportkey 关联 | 本轮样本里 feed 页 URL 与 stodownload URL 的 exportkey **不重叠**（见 5.2），不能直接拿 exportkey 当视频主键。 |

## 5. 本轮新发现的可用线索

### 5.1 feed 页 URL 携带对象标识
renderer 31312 记录区相邻两条 ASCII URL（命中地址 `0x1a04c1eb096` 附近）：

```text
https://liteapp.weixin.qq.com/a/finder/wxalite28e098851253e34f4777f7ca024236fd/pages/lite/feed?oid=z8TcEpbTCTA&nid=kuNcQgf4rpE&entrance_id=1002
https://finder.video.qq.com/251/20302/stodownload?encfilekey=nLWUlAoVvywFBEjUaZkYr4iaV5RvaFtlTe2wvkLkiak1NBkTD1IjAicQlxNu40vkfOfm0v0H2LQI1IOnr6Iv81hYw&bizid=1023...
```

- feed 页 URL 带 `oid`（对象 id）、`nid`（节点 id）、`entrance_id`。
- 这是上层"对象标识"与"流 URL"在同一条请求记录里相邻出现的实证，但标题不在该记录内。

### 5.2 flows.log 里的接口分布（657 条，旧会话 10:47 落盘）

| 主机 | 条数 | 说明 |
|---|---|---|
| finder.video.qq.com | 513 | 视频/封面 stodownload |
| res.wx.qq.com | 69 | liteapp/消息页 JS/CSS |
| findera4.video.qq.com | 60 | 视频分段下载（Range 206） |
| channels.weixin.qq.com | 8 | feed 页 HTML、report-perf POST |
| mp.weixin.qq.com | 5 | 监控/错误页 |
| 其它 | 2 | 缩略图/CDN |

- feed 页：`GET /web/pages/feed?oid=...&nid=...&entrance_id=1002&exportkey=...&pass_ticket=...`，响应 200，4284 字节（壳页面，body 未落盘）。
- report-perf：`POST /web/report-perf?pf=lite|web`，响应 201，body 53 字节（未落盘）。
- **未观察到独立的 feed 列表 JSON XHR 端点**；列表模型可能随 feed HTML 内嵌，或经原生 IPC 从主进程推给 CEF（不走代理）。

### 5.3 URL 内可提取的关联字段（供后续建表）

- feed 侧：`oid`、`nid`、`exportkey`、`pass_ticket`。
- 视频侧：`encfilekey`、`m`、`token`、`basedata`、`uzid`、`idx`、`taskid`、`exportkey`、`pass_ticket`。
- 本轮样本 exportkey 两侧不重合；`oid/nid` 只出现在 feed 页，未出现在 stodownload URL。需要 body 或内存模型才能补齐第三段映射。

## 6. 未决方向（按性价比排序，均未验证）

### 6.1 落盘非媒体响应体，验证 feed HTML / report-perf body 是否含映射（首选）
- 现状：`capture.py` 对非媒体响应只记 URL/状态/大小，不读 body；媒体响应强制 `stream=True` 不缓冲。
- 实验：对 `channels.weixin.qq.com` 的 feed HTML 与 report-perf POST body 落盘到 `work/feed_bodies/`，按键时间 + oid/nid/exportkey 命名；检查 body 是否含 `title/desc/nickname/oid/nid/encfilekey`。
- 若 feed HTML 内嵌 SSR 卡片 JSON：可直接建 `oid/nid ↔ 标题/作者 ↔ 流键` 对照。
- 脚本改动点：`capture.py` response() 内对非媒体、非 JS/CSS 资源写 body；注意不要缓冲视频。

### 6.2 renderer 堆的 V8 UTF-16 串 / 原生结构对象
- 现有扫描偏 ASCII；下一步按 UTF-16LE 提取干净中文段，反向定位同对象内的 `oid/nid/encfilekey/url` 字段。
- 可做"两次快照差分"：切换视频前后各扫一次，新增/消失的中文串与流键集合做差集，识别当前卡片模型对象。

### 6.3 xplayer ↔ 网络服务/renderer 的句柄、管道、IPC 标识
- 枚举进程句柄/命名管道，看播放器与上游之间用什么标识绑定流；成本高、结构随版本变。

### 6.4 加密 DB 的 SQLCipher 密钥
- sns.db / message_resource.db 等全加密；若能从进程内存提取 SQLCipher 密钥，可离线查 `oid/nid ↔ 标题/作者` 持久对照。未探查。

### 6.5 既有 HUD 绑定链路复核
- `wx-hud.ps1` 当前：作者主页卡片走 UIA 取 `Description + Duration` 作卡片 key；悬停停留后从 flows 候选里按 `HasM`/`MaxEnd`/`First` 选一条绑定（仍是顺序/大小启发式）。
- 播放窗口模式无 `page-profile`，UIA 识别不到卡片，F8 不做猜测；标题/文案在绑定瞬间未持久化（known-issues #12 移除 title 时一并丢失）。

## 7. 阶段结论

1. 用户判断成立：下层网络流是无序集合，按时间/顺序猜配必然错配；权威对照在上层模型对象里。
2. "播放器实例持有可读流 id/url"在播放器进程内不成立——它是瘦 slave，只收句柄/IPC。
3. 目前在所有已探查进程的明文内存/缓存/成品文件里，**尚未找到**"标题 ↔ 流 id/url"的同对象明文对照。
4. 最有希望的未触达来源：feed 页/接口响应体（6.1），其次是 renderer 堆 UTF-16/原生模型对象（6.2）。
5. 在拿到 6.1/6.2 的实证之前，继续按流量顺序绑定都属于猜测，不应作为可靠链路。

## 8. 本轮新增/使用的工具

- `tools/mem-json.py`：renderer 内存 ASCII 模型 JSON 定位器（`{"` 开头 + JSON 键/UTF-8 中文过滤）。
- `tools/mem-scan.py`：跨进程内存字符串扫描（只读，`--needle/--enc/--ctx/--max-hits/--out`）。
- `tools/mem-region.py`：单区域 dump，UTF-8 / UTF-16LE / UTF-16BE 双端解码。
- 扫描输出：`work/mem_url_ctx.json`（URL 记录宽上下文）、`work/mem_main.json`（主进程流引用扫描）、`work/mem_render.json`、`work/mem_model.json`。

---

## 9. 前端 JS 逆向（第二轮，hover/profile 窗口方向）

静态 bundle 从 `res.wx.qq.com` 拉取到 `work/js-ref/`（公开静态资源，无需会话）：`FinderFeedCard / feed / profile / vuexStores / FinderHome / worker-client / virtual_svg-icons`。

### 9.1 卡片模型字段（前端 feed 对象，mega bundle 内 Feed 类）

| 字段 | 含义 |
|---|---|
| `id` / `objectNonceId` / `encrypted_objectid` | 稳定对象标识（objectid / nonceId / 加密 id） |
| `objectDesc.description` | 标题/文案（富文本 text/textNodes） |
| `objectDesc.mediaType`、`objectDesc.media[]` | 媒体类型、媒体列表 |
| `contact.username` / `contact.nickname` | 作者标识 / 作者昵称 |
| `media.url` + `media.urlToken` | 流地址拼接基址 + token；`videoUrl = https(url + urlToken)`，主机 `wxapp.tc.qq.com` → `finder.video.qq.com` |
| `media.decodeKey` | 解密密钥（加密视频标记） |
| `media.videoPlayLen` | 时长（秒，前端格式化为 mm:ss） |
| `media.spec / hdrSpec / width / height / fullThumbUrl` | 清晰度规格、宽高、封面 |
| `likeCount / friendLikeCount / commentCount / forwardCount / favCount / likeList / likeFlag` | 点赞/评论/转发/收藏/点赞列表 |
| `attachmentList.attachments[0].video` | 附件视频对象 |
| `objectExtend.pcFinderHotComment / advertisementInfo` | 热评 / 广告信息（列表穿插广告的来源字段） |

- 一张卡片 = 一个 feed 对象；列表里可穿插广告对象（`isAd` + `objectExtend.advertisementInfo`），与用户"推荐列表穿插广告"的假设一致。

### 9.2 列表/详情走原生 MM cgi，不走 mitmproxy HTTP

前端经 `feedTransferService` 调原生协议（不是普通 HTTP XHR），所以 `flows.log` 里看不到 feed 列表 JSON。关键 cgi（`pc` 走主进程协议，`ilink` 走 link 服务）：

| 动作 | cgi | cmdid |
|---|---|---|
| 作者主页列表 | `pc_finderuserpage` | 6624 |
| 作者主页预览 | `pc_finderuserpagepreview` | 20142 |
| 播放历史/播放列表 | `pc_findergetplaylist` | 9586 |
| 相关推荐 | `pc_findergetrelatedlist` | 5222 |
| 已互动列表 | `pc_findergetinteractionedfeedlist` | 24159 |
| 对象详情 | `pc_findergetcommentdetail` | 5259 |
| 关注/收藏/点赞列表 | `pc_findergetfollowlist / favlist / likedlist` | 9758 / 11046 / 6418 |

- 详情请求参数：`objectid / objectNonceId / encrypted_objectid / finderUsername / scene / direction / identityScene / pullScene`。
- 响应是 protobuf 结构，落到上层模型对象后再分发给 CEF renderer 渲染。

### 9.3 renderer 堆里只拿到属性名，值不在 ASCII 区

- 对 6 个 renderer + link + 主进程扫模型键 `urlToken / decodeKey / objectNonceId / videoPlayLen / fullThumbUrl / attachmentList`：
  - renderer 26772 / 30060 命中这些**属性名串**（V8 内部化键），邻近是字节交换 ASCII/二进制，值不在 ASCII 相邻区；
  - link 28852、wxpublic 14812、wxutility 40876 零命中；
  - 主进程 40512 命中 `objectNonceId`，且是可读 XML 记录（见第 10 节）。

## 10. 突破：主进程内存里存在可读的"卡片 ↔ 流"对照记录（已实证）

### 10.1 实证结果

主进程 `Weixin.exe` 40512 内存中存在 ASCII XML 卡片记录（分享/卡片 appmsg，`type=51`），一条记录内同时包含：

- `objectNonceId`（稳定对象 id）
- `desc`（标题/文案，UTF-8 中文）
- `nickname`（作者昵称）、`username`（作者 v2_...@finder）、`avatar`（头像 URL）
- `mediaCount`
- 同记录邻近窗口内挂着 **3 条 stodownload URL / encfilekey**（对应 20302 / 20304 / 20350 三个码率）

本轮快照提取到 3 条（`work/mem_cards.json`），样例：

| nickname | objectNonceId 前缀 | desc 摘要 | 首条 encfilekey 前缀 |
|---|---|---|---|
| 杠京-北京杠爷 | 10584404987922132625_4_141_84 | 带领男女老少用宫廷盘杠中的动作强身健体… | 6xykWLEnztLcibAo7sNA… |
| 清一色-幽默油条喜剧 | 2578409198289497520_4_141_84 | 我今天体验感给他拉满了 #幽默油条清一色… | nLWUlAoVvywKU234gpX6… |
| 前秀楼 | 9286077877963002264_0_1_0_0 | 盛夏平武，气候宜人…（伦巴舞《梁祝情歌》） | 6xykWLEnztLcibAo7sNA… |

- 首条 `6xyk…` / `nLWU…` 与旧会话 flows.log、主进程早前扫描里的样例键一致，证明记录与实际取流同源。
- 3 条记录数量与"当前可见的一小批卡片"量级吻合，不像长期历史缓存；但**是否随列表滚动实时增删，还需两次快照差分验证**（见 11.1）。

### 10.2 记录结构（ASCII XML 骨架）

```xml
<msg><appmsg appid="" sdkver="0">
  <title></title><des></des><action></action><type>51</type>...
  <nickname>…</nickname>
  <avatar>https://wx.qlogo.cn/finderhead/…</avatar>
  <desc>…标题/文案…</desc>
  <mediaCount>1</mediaCount>
  <objectNonceId>…</objectNonceId>
  <username>v2_…@finder</username>
  <authIconType>1</authIconType><authIconUrl>…</authIconUrl>
</appmsg></msg>
```

- XML 内 `title/des/url/lowurl` 为空；文案在 `<desc>`。
- 3 条码率 URL 不在 appmsg XML 标签内，而在邻近的原生媒体对象结构里；当前提取按 ±1600 字节窗口就近配对。**邻近配对仍有跨卡片串扰风险**，正式实现需要按原生结构边界精确切分（见 11.2）。
- 该 XML 片段里未直接看到时长/点赞数字；这些字段在前端模型 `media.videoPlayLen / likeCount` 中，可能在主进程另一段结构或 renderer 模型里，待补扫。

### 10.3 对原假设的最终判定

1. "关联在上层、下层不能猜"——成立，且已定位到上层落点：**主进程 40512 的卡片模型镜像**。
2. "播放器进程持有可读流 id/url"——不成立（xplayer 是瘦 slave）。
3. "hover 窗口每张固定 Card 有 title/时长/封面/点赞，可与流对应"——方向正确：卡片模型在主进程内存里以可读 XML 保留了 `desc/nickname/objectNonceId` 与邻近的多码率流键；不需要再按流量顺序猜配。
4. 现有 `card_media.json` 用"文案|时长"作 key、绑定时刻的 URL；文案变化会 miss，且绑定仍受多卡片同时取流干扰。新链路应改为：**以 `objectNonceId` 为稳定主键**，内存表存 `objectNonceId ↔ desc/nickname/avatar/多码率 encfilekey/url`，下载文件回表按 encfilekey（或 `m`/内容哈希）反查主键。

## 11. 待验证实验（按优先级）

### 11.1 两次快照差分：确认表是实时当前模型
- 保持微信在线，先跑一次 `tools/mem-cards.py` 落 `mem_cards_a.json`；在 hover/profile 窗口滚动/切换到另一批卡片后再跑 `mem_cards_b.json`。
- 对比：新出现的 `objectNonceId` 是否对应新卡片，旧卡片记录是否退役；确认表不是一次性的历史分享缓存。

### 11.2 精确切分原生结构，消除邻近串扰
- 现在按 ±1600 字节窗口就近把 URL 配给卡片；需要按内存结构边界（记录头/长度字段/相邻记录起点）精确切分，确认每条卡片的 3 条码率 URL 确实归属该 `objectNonceId`，不混入邻卡。
- 补扫主进程记录窗口内是否含 `videoPlayLen / likeCount / cover` 字段，补全表列。

### 11.3 下载文件回表主键
- 现状：下载链路只记录 URL/encfilekey/`m`；stodownload URL 本身不带 `objectNonceId`。
- 需要确认 `m=`（32 位十六进制）是否为跨会话稳定内容哈希；若稳定，用 `m` 回表；否则下载时把当前内存表的 `objectNonceId ↔ encfilekey` 快照一并落盘，下载完成按 encfilekey 反查。
- 旧会话 encfilekey 会随会话/码率轮换，不能跨会话直接当主键。

### 11.4 降级备选（已被本轮结果降低优先级）
- 落盘 channels.weixin.qq.com feed HTML / report-perf body（任务 #4）：列表主体走原生 cgi 不经代理，HTTP body 大概率拿不到完整列表映射，仅作兜底观察。
- 加密 DB 的 SQLCipher 密钥提取、xplayer 句柄/管道 IPC 反推：成本高、随版本变，仅在 11.1–11.3 走不通时再评估。

## 12. 本轮新增工具与产物

- `tools/mem-json.py`：renderer ASCII 模型 JSON 定位器。
- `tools/mem-cards.py`：主进程卡片 XML 记录提取器（`--pid/--max/--out`，抽 desc/nickname/objectNonceId/username/avatar/URL/encfilekey/`m`）。
- `tools/mem-ascii.py`：指定地址周围 ASCII 可打印串转储（带偏移）。
- `work/js-ref/`：finder 前端 bundle 副本 + `grep_ctx.py`（关键词上下文）、`cgi_map.py`（cgi/cmdid 表提取）。
- `work/mem_cards.json`：本轮主进程卡片对照记录；`work/mem_modelkeys.json`：模型键跨进程扫描；`work/mem_cards` 提取脚本见 `tools/mem-cards.py`。

---

## 13. 决定性结构：`<finderFeed>` 自包含 XML（已实证，无需邻近猜测）

### 13.1 结构边界（hex 实证，主进程 40512）

主进程内存里的卡片不是零散字符串，而是一个完整自包含的 XML 元素 `<finderFeed> … </finderFeed>`，标题/作者/对象 id/多码率流地址全部在同一元素内，按标签边界切分即可，不需要按地址距离猜配：

```xml
<finderFeed>
  <nickname>杠京-北京杠爷</nickname>
  <avatar>https://wx.qlogo.cn/finderhead/…</avatar>
  <desc>带领男女老少用宫廷盘杠中的动作强身健体…#单杠 #宫廷盘杠 #公园健身</desc>
  <mediaCount>1</mediaCount>
  <objectNonceId>10584404987922132625_4_141_84_0_1794752442515692_bd76c938-…</objectNonceId>
  <username>v2_060000231003…@finder</username>
  <authIconType>1</authIconType><authIconUrl>https://dldir1v6.qq.com/…/auth_icon_level3_….png</authIconUrl>
  <mediaList>
    <media>
      <url>…/20302/stodownload?encfilekey=6xyk…&amp;hy=SH&amp;idx=1&amp;m=7344b359…&amp;uzid=7a22e</url>
      <coverUrl>…/20304/stodownload?encfilekey=2fG3…&amp;token=oA9…&amp;m=43f0784d…&amp;uzid=1</coverUrl>
      <thumbUrl>…/20350/stodownload?encfilekey=2fG3…&amp;token=oA9…&amp;m=f600ca62…</thumbUrl>
      <width>1080</width><height>1920</height>
    </media>
  </mediaList>
</finderFeed>
```

- 变体分工：`url`=20302 原画视频流；`coverUrl`=20304 封面；`thumbUrl`=20350 缩略图。
- 每个变体带 `encfilekey`、`token`（封面/缩略图）、`m`（32 位十六进制内容哈希，部分卡片为空）、`uzid`、`idx`。
- XML 内 `&` 被转义为 `&amp;`，解析前需先反转义，否则 `m/uzid` 会解析为空。

### 13.2 本轮提取到的 3 条干净对照（`work/mem_feeds.json`）

| objectNonceId 前缀 | nickname | desc 摘要 | 原画 encfilekey 前缀 | 原画 m | 尺寸 |
|---|---|---|---|---|---|
| 10584404987922132625_4_141_84 | 杠京-北京杠爷 | 带领男女老少用宫廷盘杠… | 6xykWLEnztLcib | 7344b359a710… | 1080×1920 |
| 2578409198289497520_4_141_84 | 清一色-幽默油条喜剧 | 我今天体验感给他拉满了 #幽默油条… | nLWUlAoVvywKU2 | （空） | 1080×1920 |
| 9286077877963002264_0_1_0_0 | 前秀楼 | 盛夏平武…《梁祝情歌》 | 6xykWLEnztLcib | 54e7fc1a1751… | 1920×1080 |

### 13.3 对"nonceId 能否对接流 URL"的判定

**能，而且就在同一 XML 元素内直接对接。** `objectNonceId` 是稳定主键，同元素 `mediaList/media/url[encfilekey,m,uzid,idx]` 就是它对应的原画流；封面/缩略图在 `coverUrl/thumbUrl`。这推翻了"必须在播放器进程或网络记录里猜配"的路径：

- 不再需要按流量时间/顺序绑定；
- 不再需要邻近地址距离判断（13.1 证明标签边界本身就是归属边界）；
- 回表链路：下载时快照内存表 `objectNonceId ↔ desc/nickname/avatar/encfilekey(原画)/m/尺寸`，成品文件按 encfilekey（优先）或 `m` 反查 nonceId，再取标题/作者。

### 13.4 仍待验证的点

1. **这 3 条是在线 hover/profile 列表卡片，还是聊天分享消息残留**：元素尾部带有 `<fromusername>wxid_…</fromusername><appinfo>`，疑似转发/分享卡片。需要在作者主页（hover 固定卡片列表）打开一批新卡片后重跑 `tools/mem-feed.py`，确认：(a) 新卡片同样以 `<finderFeed>` 落主进程内存；(b) 滚动/切换后旧记录退役、新记录进入；(c) 卡片数量与可见列表一致。
2. **回表主键稳定性**：`encfilekey` 随会话/码率轮换，不能跨会话当主键；`m=` 疑似内容哈希但部分卡片为空、跨会话是否稳定未验证；`objectNonceId` 最稳，但成品 MP4 不带它，必须在下载当下把内存快照一并持久化。
3. **时长/点赞数**：本 XML 只给宽高，未含 `videoPlayLen/likeCount`；这些字段在前端模型或 renderer 模型里，主进程该 XML 片段未携带。
4. 广告对象是否也走同一 `<finderFeed>` 结构、`objectExtend.advertisementInfo` 标记在哪个字段，尚未在样本里见到。

### 13.5 对应工具

- `tools/mem-feed.py`：按 `<finderFeed>…</finderFeed>` 标签边界解析主进程内存卡片表（`--pid/--out`），输出 `work/mem_feeds.json`。
- `tools/mem-hex.py`：指定地址十六进制转储（核对 XML 字节边界用）。
- `tools/mem-pair.py`：URL/卡片地址就近对照（辅助排查，正式链路用 `mem-feed.py` 的标签边界，不用距离配对）。

---

## 14. Live 验证：打开作者主页后的实测结果（2026-11-16 13:31）

操作：在微信里打开视频号作者主页"杠京-北京杠爷"（hover 可取流的固定卡片网格），随后重扫。

### 14.1 UIA 在主页模式下能读到整张卡片网格（与播放窗口模式不同）

- 之前 UIA 内容区为空，结论来自**播放窗口模式**；作者主页模式下 CEF 窗口（40116）暴露 352 行，卡片网格可读：
  - 每卡片：封面 `prev-i` Image、时长 Text（如 `01:22`）、点赞数 Text（如 `1.2万`）、文案 Text；
  - 4 列网格，卡片按 DOM 顺序排列，`click-box` 带明确 Rect（如 `1065,462 178x281`）；
  - 本轮可见约 30 张卡片，文案/时长/点赞均可文本读取。
- **但卡片元素不带 `AutomationId`/对象 id/nonceId**，UIA 层只有顺序、矩形、文案、时长、点赞数。
- 样本转储：`work/uia_dump_20261116_133159.json/.txt`；网格映射脚本 `work/uia_map.py`。

### 14.2 主进程 `<finderFeed>` XML 不是实时主页列表（负向结论）

- 打开主页前后两次跑 `tools/mem-feed.py`：仍是同样 3 条记录、同样 encfilekey/m，无新增、无退役。
- 判定：主进程这 3 条 `finderFeed` 是**聊天分享/转发卡片的残留镜像**（尾部带 `<fromusername><appinfo>`），不是作者主页实时列表；不能拿它当当前卡片表的实时来源。
- 干净的 `objectNonceId ↔ url` 自包含结构在 XML 层面成立，但对**实时主页卡片**，这份 XML 当前并不随列表刷新。

### 14.3 实时列表模型在 renderer V8 堆里，字符串扫描拿不到成对象

- 打开主页后新 renderer 42088 持有实时列表：UTF-16 文案串按 DOM 顺序成簇出现（"世界记住了这一刻…"→"这套动作你肯定没见过…"→"今天是女生专场…"…，与 UIA 卡片顺序一致）。
- 堆内对象槽位是二进制/V8 内部结构；`objectNonceId / media.url / encfilekey` 与文案不在相邻 ASCII 区，按字符串扫描无法把单条 nonceId/URL 挂到具体文案上。
- 区域内 ASCII 片段只有作者级 `oid=z8Tc…` 和作者 username 哈希（主页头部信息），不是逐视频对象 id。
- 其它 renderer（42836 等）零命中；主进程/link/wxpublic/wxutility 不持有实时列表文案。

### 14.4 现阶段可落地与待攻坚的分层结论

| 层 | 能读到什么 | 局限 |
|---|---|---|
| UIA 主页网格 | 顺序、矩形、文案、时长、点赞、封面图 | 无对象 id；只能在主页模式读，播放窗口模式读不到 |
| 主进程 finderFeed XML | 自包含 nonceId/文案/作者/多码率 URL（结构完整） | 是分享残留，不随实时列表刷新 |
| renderer V8 堆 | 按序的文案串 + 模型对象 | 对象槽位二进制，需 V8 堆解析才能取出逐卡片 nonceId/URL |
| 原生 MM cgi | `pc_finderuserpage(6624)` 等列表接口 protobuf 响应 | 走原生协议不经代理，需协议逆向或内存解密 |

**可立即采用的稳妥绑定思路（不依赖取 nonceId）**：
1. 主页模式下用 UIA 枚举卡片网格（顺序 + Rect + 文案/时长/点赞）；
2. 悬停绑定改为**作用域限定**：跟踪鼠标 enter/leave 的 `click-box`，只把该悬停卡片停留期间到达的流记录绑给它，不再从全局 flows 池按 MaxEnd/First 挑候选；
3. 用封面做二次锚定：每张卡片封面已在渲染，封面 URL/encfilekey 与可见封面对应，可辅助校验流记录归属；
4. 下载落库时把当时 UIA 读到的文案/时长/点赞/作者/矩形一并持久化，避免重现 known-issues #12 标题丢失。

**仍需攻坚才能拿到权威主键**：renderer V8 堆对象解析，或原生 cgi protobuf 响应/密钥提取；在此之前 `objectNonceId` 无法从实时卡片直接回表。

---

## 15. 突破：renderer 堆里存在逐卡片打包记录（nonce ↔ object_id ↔ 时长 ↔ 点赞 ↔ 流键同区）

### 15.1 记录布局（renderer 42088，ASCII 打包，非纯 V8 二进制槽位）

在 `0x1ce01900000 / 0x1ce01910000 / 0x1ce01bd0000` 等 64KB 桶区，按地址顺序排列逐卡片记录，每条结构：

```
[nonceId] [base64(recsys JSON)] [20302 原画 URL/encfilekey] [20304 封面] [20350 缩略图] …
```

- `nonceId`：`{objectId}_{...}_{request_id}_{scid-uuid}`，前缀即数字 objectId，后缀 scid 与 JSON 内 `scid` 一致。
- base64 解码后是 recsys/上报元数据 JSON，已确认字段：
  - `object_id`（数字主键）、`related_feed_id`、`feed_pos`、`tab_feed_pos`（列表位置序号）
  - `vid_len`（时长秒，与 UIA 卡片时长一致）、`cur_like_count`、`cur_comment_count`
  - `media_type`、`create_time`、`delivery_time`、`request_id`、`scid`、`secrete_data`、`oflag`、`ad_flag` 等
- 同一记录窗口内紧跟该卡片的 `20302`（原画）/`20304`（封面）/`20350`（缩略图）`stodownload` URL 与 `encfilekey`（部分卡片未悬停时原画键为空，悬停取流后填充）。
- 解析脚本：`tools/mem-model2.py`（nonce 定位 → base64 解码 → URL 变体抽取）；输出 `work/mem_model2.json`。

### 15.2 与 UIA 主页网格的对齐验证（按时长 vid_len）

- UIA 转储 60 张卡片，时长为 `mm:ss`；内存 25 条已解码记录中，前 24 张可见卡片有 **13 张时长精确命中**（如 34s/29s/194s/46s/63s/91s/45s/124s/102s/33s…）。未命中的多在尚未解码的记录里。
- 解码修复：base64 尾部常混入下一段编码数据导致 `Extra data`，需截到最后一个平衡 `}` 再解析（`mem-model2.py` 已处理）。
- **`vid_len`（时长秒）是当前最稳的 1:1 对齐信号**；`feed_pos` 是全局位置序号，不等于网格下标，需结合时长校验。
- 注意：打包记录里 `cur_like_count` 相对本卡片存在一位偏移（时长对得上、点赞落到邻卡），因此**点赞数与文案仍以 UIA 为准**，内存记录只提供主键/时长/流键。
- 对齐辅助脚本：`work/match_len.py`（按时长回表）、`work/match_uia_mem.py`。

### 15.3 结论（回答"nonceId 能否对接流 URL"）

**可以。** 权威关联不在下层流量池里猜，而在 renderer 上层模型的打包记录中：`nonceId / object_id` 与本卡片原画 `20302 encfilekey` 同记录相邻存放，时长 `vid_len` 可与 UIA 卡片精确回表。这替代了原先"按文案|时长 + 全局 flows 候选挑一条"的启发式绑定。

### 15.4 仍待补齐（任务 #7）

1. 60 条 nonce 中 22 条 base64 解码成功，其余需排查窗口长度/截断/非 base64 形态，争取全量解码。
2. UIA 平铺 Text 需按 `click-box` 矩形归属分组，把时长/点赞/文案/封面正确归到同一张卡片（当前扁平顺序提取存在点赞错位）。
3. 落库表：`nonceId / object_id / feed_pos / vid_len / encfilekey(20302) / cover(20304) / thumb(20350) / desc / 作者 / 点赞 / 坐标`；悬停时回填流键，未悬停卡片先存主键与元数据。
4. 待验证：`m=` 跨会话稳定性、encfilekey 轮换后以 `object_id/nonceId` 回表；文案/作者在内存中的存放结构（当前从 UIA 取）。

### 15.5 对齐落库脚本与首轮结果（任务 #7）

- 脚本：`tools/card-join.py`。先按 `click-box` 矩形归组 UIA 元素（封面 Image / 时长 Text / 点赞 Text / 文案 Text），再与内存记录按时长 `vid_len == 时长(秒)` 对齐，输出 `work/card_merged.json`。
- 首轮（42088 在线、主页"杠京-北京杠爷"60 张卡片）：**24/60 按时长匹配成功**（重复时长不重复占用同一内存记录）；未匹配主要落在尚未解码的记录上。
- 内存打包记录观察到三种形态：
  - **A（已解码）**：nonce → base64 recsys JSON → 20302/20304/20350 URL；
  - **B**：nonce → `v2_<hex>@finder` 加密对象 token → 头像/封面 URL，无内联 recsys JSON；
  - **C**：nonce 附近无 blob、无 URL（元数据在并行 V8 对象里）。
- 已知局限：
  1. 时长重复的卡片（如 34s 出现 3 次）在只有一条内存记录时无法区分，需用 `feed_pos`/顺序或点赞二次校验；
  2. 未悬停卡片的 20302 原画键为空，需悬停取流后回填；
  3. 点赞/文案以 UIA 为准，内存记录只承担主键/时长/流键；
  4. 35 条未解码记录中，短 base64（132–142 字符）是 `v2_...@finder` token 或 `secrete_data`，不是 recsys JSON。

### 15.6 悬停回填与内存键缓存（本轮新增）

- 新增 `tools/mem-keys.py`：抽取逐卡片权威对照表（`object_id/nonce/feed_pos/vid_len/like/comment` + `media.20302|20304|20350` 的 `encfilekey/m/token`），输出 `work/mem_keys.json`。
- URL 归属改为“归到前面最近的 nonce、间距 <3000 字节”，避免窗口越界串到邻卡。
- 实测（42088，未翻页）：60 条记录，17 条带 20302 原画键；与 UIA 对齐的 24 张卡片里 9 张已带键，其余待悬停回填。
- 进程识别注意：所有 renderer 父进程都是 40116，父进程关系不能区分；**判定“当前主页列表在哪个 renderer”的仲裁依据是：该 renderer 的记录按时长能对上当前 UIA 网格**，而不是 nonce 命中数最多（另一 renderer 26772 有 75 条，属别的列表）。
- 下载 URL 可由内存记录重建：`https://finder.video.qq.com/251/20302/stodownload?encfilekey=<key>&m=<m>&token=<token>`；`uzid` 字段常被二进制/邻卡 URL 污染，暂不采用。
- 待接入：HUD 悬停绑定时优先查内存键表（按时长/顺序命中即用其 encfilekey），内存缺记录时才回退流量池；悬停后定时重扫回填新出现的键。

### 15.7 60 条主键提取结果（本轮交付）

- 导出脚本 `work/export_keys.py`，产物 `work/primary_keys.json`：60 行，每行 `object_id / nonce / feed_pos / vid_len / like / comment / key_20302|20304|20350 / has_meta / has_stream`。
- 覆盖统计：**主键 60/60 已解出**；其中 25 条带内联元数据（时长/点赞/位置），17 条带原画流键。
- 35 条缺内联元数据的记录：全堆扫描确认其 object_id 只出现在 nonce 引用处，没有第二份明文 JSON 副本；模型对象在 V8 二进制槽位里，字符串扫描够不到。要补齐需 V8 堆对象图解析，或拦截原生 cgi protobuf 响应（当前无调试端口、DB 加密，均未打通）。
- 运行时绑定不依赖这 35 条的内联元数据：时长/点赞/文案由 UIA 提供，内存记录提供 `object_id/nonce/encfilekey`，按时长+顺序回表即可。

### 15.8 关于“能否用微信自己的方法触发取流”

- 当前**无法**从外部主动触发某张卡片取流：取流由 CEF 页面 JS / 原生 MM 模块在悬停时发起；没有暴露 CDP 调试端口，页面内部函数不可直接调用；复刻原生 cgi 请求需要 protobuf 结构与会话密钥，尚未拿到。
- 取流参数（`encfilekey/token`）是服务端短时签名凭证，**过期后不能复用**；所以正确做法是在悬停取流的当下，把稳定主键（`object_id/nonce`）和刚拿到的流键成对捕获落库，而不是事后再用稳定 id 反推 URL。
- 现阶段能做的“主动刷新”只有：让用户在主页移动悬停，触发对应卡片取流，再由内存扫描回填键表。

---

## 16. 新下载界面设计（独立于现有 wx-gui / wx-hud）

### 16.1 产品流程（对应用户描述）

1. 打开微信视频号作者主页 → 界面列出全部 Card：封面 / 标题 / 时长 / 点赞；
2. hover 取流后，判定该流对应列表里哪一条卡片；
3. 按规则判断这条是否可下载；
4. 点下载按钮落盘。

### 16.2 分层与数据源（均为已验证来源）

| 层 | 职责 | 数据来源 |
|---|---|---|
| 采集后端 collector | 枚举 UIA 卡片网格；扫描内存打包记录；产出卡片列表快照 JSON | UIA `click-box` 树；`tools/mem-keys.py` 堆扫描 |
| 展示前端 UI | 卡片网格/列表、状态徽标、下载按钮、进度 | 读取 collector 产出的 JSON |
| 下载执行 | 密文下载 + 取内存 MP4 头拼接 + 校验落盘 | 复用 `wx-dl.ps1`（`-SaveUrl -SaveTag -ExpectedDuration`） |

### 16.3 卡片状态机

- `pending`：已枚举，流键尚未取到；
- `ready`：内存记录已有 20302 原画键，可下载；
- `downloading`：下载进行中；
- `done`：已落盘（记录文件 / 大小 / 分辨率 / 时长）；
- `failed`：候选下载失败，待重放。

### 16.4 绑定解析（第 2 步，替代旧流量池猜测）

1. 悬停/选中卡片 → 在内存键表中按 **时长 vid_len + 网格顺序** 命中记录，点赞做交叉校验；
2. 命中则用该记录重建下载 URL：
   `https://finder.video.qq.com/251/20302/stodownload?encfilekey=<key>&m=<m>&token=<token>`
3. 内存缺记录时，才回退现有流量池候选（`HasM/MaxEnd/First`）作兜底；
4. 落库主键用 `object_id/nonce`，`m/encfilekey` 为辅助字段；记录 desc / 作者 / 时长 / 点赞 / 流键 / 文件 / 状态 / 更新时间。

### 16.5 刷新模型

- UIA 卡片列表：后端每 1–2 秒枚举一次；
- 内存键表：后端每 10–15 秒重扫一次；
- 前端轮询快照 JSON 渲染，不直接读进程内存。

### 16.6 待决：技术栈

- 方案 A（倾向）：Python 标准库本地 HTTP 后端（复用 `mem-keys.py`）+ 静态 HTML/JS 前端，封面网格好渲染、无需编译 WPF；
- 方案 B：WPF / PowerShell，与现有脚本同栈。

### 16.7 快速验证模型（已落地，方案 B）

- 脚本：`tools/validate-binding.ps1`。流程：UIA 枚举主页卡片 → 载入 `work/mem_keys.json` → 按时长 vid_len 对齐（记录不重复占用）→ 点赞交叉校验 → 输出明细表 + `work/validate_bind.json`。
- 实测（42088，当前视口 10 张）：**匹配内存记录 6/10**，点赞一致 4/6；视口内已匹配卡片暂无原画键（17 条带键记录在屏外卡片）。
- 验证结论：UIA 枚举与内存记录按时长/顺序回表在机制上跑通；未匹配的 4 张对应尚未解码的 B/C 形态记录。
- 待做的端到端验证：悬停某张屏内卡片，观察其匹配记录是否回填 20302 键，再用该键重建 URL 走 `wx-dl.ps1` 下载。

### 16.8 堆内 URL 归因能力边界（42088 实测）

- 全堆去重后 **20302 原画 URL 60 条（每卡一条）**、20304 封面 107、20350 缩略图 64；`mem-keys.py` 目前只归因出 17 条 20302。
- 归因路径逐一证伪：
  1. **邻接窗口**（前一个 nonce 间距 <3000 字节）：仅 18 条命中，URL 字符串多在独立字符串表区，离对象槽位很远；
  2. **堆地址顺序配对**（nonce 序列与 URL 序列同序）：对 17 条可信对校验 **0/17**，两张字符串表排序不一致；
  3. **URL 参数回带主键**：`basedata` 只含清晰度档位码（`bnhXVDEx…`），`m/token/uzid/idx` 均不含 `object_id` 或 `scid`，无法从 URL 反查卡片。
- 结论：纯字符串扫描无法把剩余 43 条 URL 回挂到 nonce；真正的关联在 V8 对象内部指针（对象图）里，需要按槽位解析或做取流时刻的在线配对。
- 附带修复项：`mem-keys.py` 当前 `object_id` 取的是 nonce 首段（`nonce.split("_")[0]`），解码 blob 里的 `object_id`（19 位十进制）未保留；落库时应区分 `object_id`（blob）与 `nonce_prefix`。

### 16.9 修订后的绑定策略：取流时刻在线配对（优先于离线堆重建）

- 不再尝试离线补齐 43 条堆内归因；改为在取流当下绑定：
  1. UIA 跟踪当前悬停/激活卡片（光标命中的矩形 + 时长 + 文案 + 点赞）；
  2. 监听新到的 20302 `encfilekey`（flows.log 或网络服务内存扫描）；
  3. 新键出现在悬停时间窗内，就挂到该卡片，用时长做二次校验；
  4. 落库卡片 ↔ 键对；下载时用已落库的键重建 URL。
- 离线堆内已归因的 17 条作为冷启动补充，不走主路径。
- 待验证：本版本 hover 是否真的发起 20302 请求（本轮悬停第二张 00:55，堆内 20302 键数仍 17、无新增）；若 hover 只加载封面，取流时机需改为点击进入播放/详情。

### 16.10 悬停差分基线（待在线复测）

- 工具：`tools/hover-diff.py`，`baseline` 快照各进程 20302 键集合 → `work/keys_baseline.json`；`diff` 重扫并输出新增键及其进程/地址。
- 基线键数（PID / 名称 / 20302 键）：主进程 Weixin 40512=127；CEF 主 40116=103；网络 26600=5；renderer 26772=236；renderer 42088=297；其余进程 0。
- 主进程 40512 同样持有 63 个 nonce 与 604 条 20302，但邻接命中仅 4 条，与 renderer 一样字符串分表存放；怀疑其 cgi 响应是 protobuf 打包（object_id 与 encfilekey 为同一消息内不同定长字段），尚未按 protobuf 切片解析。
- 复测步骤：用户在主页缓慢悬停 2–3 张卡（每张停留 2–3 秒，不点开播放）→ 跑 `diff` → 看新增键落在哪个进程、能否在同进程按邻近 nonce / 时长回表到 UIA 卡片。

### 16.11 突破：主进程 40512 持有权威 `object_id ↔ encfilekey` 配对

- 悬停 4 张后差分：新增键主要落在**主进程 Weixin 40512**（19 条）、CEF 主 40116（3）、网络 26600（1）、renderer 26772（4）；主页 renderer 42088 键数未增。**取流结果先进入主进程，不在主页 renderer 堆里。**
- 主进程内存记录形态（行为/取流上报 blob）：`19 位 object_id,https://finder.video.qq.com/251/20302/stodownload?encfilekey=...&m=...&token=...`，object_id 与流 URL 逗号相邻、同一条记录内。
- 扫描工具 `tools/main-pair.py --pid 40512`，产物 `work/main_pairs.json`：28 条 `object_id ↔ 20302 键`（含 m/token/uzid/出现次数/邻近解码元数据）。
- 与 renderer 解码记录交叉核对：11/27 个 object_id 命中，时长/点赞与当前 UIA 卡片一致（如 len34/like3648、len46/like700、len63/like1911、len194/like4750、len29/like837），证明 **主进程配对 ↔ renderer 记录 ↔ UIA 卡片** 三链对齐成立。
- 主进程配对键与 renderer 堆内旧键不一致（0/17 同键）：主进程持有的是悬停当下新取到的键，renderer 堆内是早期缓存变体；**绑定应以主进程配对的新键为准**。
- 待办：
  1. 16 条 only-main 记录 renderer 无解码 blob，需用主进程邻近 base64 recsys 元数据（当前 4000 字节窗口多数未解出，需放宽到 8000 字节并校正记录边界）补时长/点赞；
  2. 正则偶发把 19 位 oid 截成 18 位（如 `5038016023823649480`），需按长度/前缀归并；
  3. 验证 20304/20350 封面/缩略图是否也以同形态与 oid 相邻。

### 16.12 卡片绑定解析器（验证模型落地）

- 管线：`validate-binding.ps1` 导出 UIA 卡片 → `card-resolve.py` 载入 `main_pairs.json` + `mem_model2.json`，按时长对齐、点赞就近做重复时长二次校验（记录不重复占用）→ 输出 `work/resolved_cards.json`。
- 每条 ready 记录含：`object_id / nonce / key20302 / m / token / 重建下载 URL / desc / like_check`；状态 `pending`=已枚举但主进程配对表还没有该卡键。
- 实测（当前视口 15 张）：命中配对 **8/15**，ready 8，点赞一致 **8/8**；重复时长（29s×2）按点赞就近正确拆分（2.1万↔21006 赞、837↔837）。
- 已知波动：主进程配对表是内存快照，个别刚悬停卡片的记录可能在两次扫描间被回收（如 63s/1911 那张本轮 pending）；界面需定时重扫 `main_pairs.json` 回填。
- 重建 URL 形态：`https://finder.video.qq.com/251/20302/stodownload?encfilekey=<key>&m=<m>&token=<token>`。

### 16.13 端到端可达性验证（URL 可下载）

- 主进程配对记录保留**原始完整 URL**（含 `basedata/sign/svrbypass/svrnonce/taskid/extg/web`），不能只凭 encfilekey/m/token 重建——去掉这些签名参数 CDN 返回 400。
- 正则边界需在 `,;[]()` 处截断，避免把上报 JSON 尾部的 `,1355116405,3,0,[v1.2.61]...` 并入 URL。
- 对 ready 卡片完整 URL 发 `Range: bytes=0-0`：**206 Partial Content**，`Content-Type: video/mp4`，`Content-Range: bytes 0-0/4196919`（约 4.2MB）。
- 结论：**UIA 卡片 → 主进程 `object_id↔完整流 URL` 配对 → CDN MP4** 链路打通；绑定不再依赖流量顺序猜测。后续落盘仍走 `wx-dl.ps1` 的内存 MP4 头拼接/校验步骤。

### 16.14 技术栈决策：Python 为主，分三期迁移

- **统一运行时**：Python **3.14.3**，解释器 `C:\Users\ASUS\AppData\Local\Programs\Python\Python314\python.exe`（已装 comtypes 1.4.16、pywin32 311、PyQt6 6.10.2、PySide6、requests、psutil、mitmproxy 12.2.3、cryptography、fastapi/flask、websockets）。注意：工具 shell 默认 `python` 可能落到沙箱 3.13.18，脚本调用须显式指定 3.14 路径。
- 三期路线：
  1. **一期**：采集 + 解析 + UI 全 Python；UIA 走 comtypes，内存读取走 ctypes；
  2. **二期（过渡）**：下载仍调 `wx-dl.ps1 -SaveUrl -SaveTag -ExpectedDuration`，作为黑盒后端，Python 编排传参；
  3. **三期（稳定后）**：内存 MP4 头提取、代理设置/还原迁入 Python，退役 PS1 主体；`wx-gui.ps1 / wx-hud.ps1` 淘汰。
- **一期纯 Python 链路已验证**：`tools/uia-collect.py`（comtypes UIA 枚举主页卡片 → `uia_cards.json`）+ `tools/card-resolve.py`（回表 `main_pairs.json`/`mem_model2.json` → `resolved_cards.json`），不再经过 PS。实测当前视口 15 张：ready 8，点赞一致 8/8，与 PS 版结果一致。
- 待办：主进程 pid 自动探测（`main-pair.py` 目前显式传 40512）；PyQt6 界面骨架读取 `resolved_cards.json` 渲染状态与下载按钮。

### 16.15 一期交付物（纯 Python 骨架）

- `tools/main-pair.py`：自动探测 Weixin.exe 主进程（取配对数最多者），扫 `object_id ↔ 完整流 URL` 配对；`--pid` 可显式指定。
- `tools/uia-collect.py`：comtypes UIA 枚举主页卡片网格 → `work/uia_cards.json`（时长/点赞/文案/矩形）。
- `tools/card-resolve.py`：UIA 卡片回表 `main_pairs.json` + `mem_model2.json`，时长对齐、点赞就近二次校验 → `work/resolved_cards.json`（ready/pending、oid、nonce、完整 URL、点赞校验）。
- `tools/refresh.py`：编排三步顺序执行，产出最新快照。
- `wx-viewer.py`：PyQt6 界面骨架，读快照渲染状态徽标/时长/点赞/文案/下载按钮；ready 可点，pending 禁用；自动刷新 15s。
- 离屏冒烟：快照 15 行、ready 8、点赞一致 8，界面渲染正常。
- **二期待接入**：下载按钮调 `wx-dl.ps1 -SaveUrl -SaveTag -ExpectedDuration`，回填 downloading/done/failed；下载编排、代理设置/还原暂留 PS 后端。
- **三期待迁移**：内存 MP4 头提取、代理兜底迁入 Python，退役 `wx-dl.ps1` 主体与 `wx-gui/wx-hud`。

### 16.16 二期：下载执行接入（wx-viewer → wx-dl.ps1）

- `wx-viewer.py` 新增 `DownloadWorker(QThread)`：后台子进程调 `wx-dl.ps1 -SaveUrl <完整URL> -SaveTag <object_id> -ExpectedDuration <seconds>`，不阻塞 UI；解析 stdout `SAVED=<path>`（exit 0）/ `FAILED`（exit 2），按回执回填 `downloading/done/failed`。
- 落库 `work/library2.json`，以 `object_id` 为键：`object_id/nonce/desc/duration/like/status/file/error/updated`；刷新快照时与库状态合并，`done/failed` 保留库态，其余回到快照 `ready/pending`；`failed` 行按钮变“重试”。
- **ffmpeg 定位**：本机 ffmpeg/ffprobe 不在 PATH，实测位于 `C:\Users\ASUS\AppData\Local\Programs\dym\resources\ffmpeg\`；worker 启动子进程时把该目录前置到 `PATH` 环境变量，供 `wx-dl.ps1` 的 `Resolve-Tool` 解析。
- **实测首条 ready 卡片**：`exit 2`，预检 `mismatch`（“地址与所有内存头都不配对”）。接线与回执判定正确；失败属运行期条件——目标视频的明文 MP4 头须已解码进 `WeChatAppEx` 内存（点开播放或悬停数秒），内存里只有别的视频头时无法拼接落盘。
- **批量实测 8 条 ready：3 条 SAVED 落盘成功**（其余 5 条内存头未入，预检 mismatch）：

| 卡片 | 时长 | 点赞 | oid | 落盘文件 | 实测时长 |
|---|---|---|---|---|---|
| idx5 | 01:31 | 2079 | 15038016023823649480 | 视频号_20261116_155956_576p_92s.mp4 | 91.8s |
| idx6 | 00:45 | 509 | 15036571014753487580 | 视频号_20261116_160001_576p_46s.mp4 | 45.9s |
| idx7 | 02:04 | 3685 | 15034382680765827803 | 视频号_20261116_160008_576p_124s.mp4 | 124.0s |

  三条时长均在 ±3s 闸门内；绑定链路为 UIA 卡片(文案/点赞/时长) → 解析回表 oid → 主进程配对完整流 URL → wx-dl 落盘。记录已写入 `work/library2.json`（done + 文件路径），界面合并状态：15 行 = ready 5 / pending 7 / done 3。
- 二期接线闭环验证通过；剩余 mismatch 卡片待其明文头进内存后可直接重试（界面按钮变“重试”）。

### 16.17 界面阻塞修复：刷新编排迁入后台线程

- 问题：`refresh_all()` 在主线程同步 `subprocess.run(refresh.py)`，而 `main-pair.py` 要扫描多个 Weixin.exe 进程内存，耗时长；15s 自动刷新和手动刷新都会冻结界面，下载点击也被连带卡住。
- 修复：新增 `RefreshWorker(QThread)`，把刷新编排放后台子进程；主线程只在 `finished_ok` 信号后 `reload_snapshot()` 重绘。`_refreshing` 标志防止刷新重叠；刷新期间禁用刷新按钮、状态显示“刷新中…”。下载 `DownloadWorker` 本就在 QThread，未阻塞主线程。
- 离屏验证：点击刷新后立即 `_refreshing=True`、按钮禁用；后台扫描完成后回到 `False` 并重载 15 行，主线程不再等待。
- 待观察：`main-pair.py` 自动探测会串行扫描所有 Weixin.exe 候选，是刷新链路里最重的一段；三期可限定主进程 PID 或缩短扫描范围以降低后台负载。

### 16.18 下载失败归因复查：不是 URL 过期，是内存头未入

- 对当前 ready 卡片流 URL 做 HEAD（`--noproxy`、带 Referer/UA）：9 条中 8 条 **200**，带 `Content-Length` 与 `X-enclen=131072`；1 条（此前已下载的 124s 卡片）返回 **400**（地址已轮换）。**没有 403/401**，即绝大多数失败不是签名过期。
- `tools/diag-headers.ps1` 枚举 WeChatAppEx 内存明文 MP4 头：仅 renderer 42088 有 3 个头——
  - `moovEnd=1468 declared=148437`、`moovEnd=1468 declared=89354`：短片/广告头，与任一 ready 流长度都对不上；
  - `moovEnd=101250 declared=10698624`：与 idx10（91.8s，已落盘那条）`Content-Length=10698624` 精确一致。
- 结论：下载失败停在 `Test-UrlHeaderPreflight` 的 mismatch——目标视频的明文头还没解码进 WeChatAppEx 内存，内存里只有别的片子的头；密文首段要靠内存头拼接，头不在就无法落盘。hover 取到的是加密流键/URL，不等于头已解码。
- 提升成功率的方向：目标视频需在播放器里实际解码过几秒（头进内存），再回到界面重试；或三期在 Python 侧另找明文头来源（本地缓存分片/播放器解码缓冲）。
- 界面加固：`RefreshWorker` 不再静默吞错——刷新结果写 `work/refresh.log`（含解释器路径/退出码/输出），失败时状态栏显示“刷新失败: …”。

### 16.19 刷新 gbk 编码崩溃修复 + 界面调试面板

- **崩溃现象**：刷新编排报 `UnicodeEncodeError: 'gbk' codec can't encode character '\u027c'`，定位在 `refresh.py` 把捕获到的输出 `print` 到管道；Windows 默认 gbk 控制台/管道编码遇到生僻字无法编码。
- **修复**：`refresh.py` 启动时把 `stdout/stderr` `reconfigure(encoding="utf-8", errors="replace")`；子进程环境加 `PYTHONUTF8=1`。已实跑 `refresh.py` 退出 0，快照正常产出。
- **调试面板**：`wx-viewer.py` 表格下方新增只读调试区，选中行（或下载完成后自动）回填：状态/时长/点赞/文案、`object_id`/`nonce`、失败原因、已保存文件路径、完整流 URL；pending/failed 附操作提示（先悬停/播放再重试）。失败原因来自下载回执分类：内存头未入、地址过期、缺少 ffmpeg、解码校验失败等。

### 16.20 切换账号后界面不实时的排查与修复

- **现象**：在微信里 hover / 切换到另一个视频号后，重启 `wx-viewer` 仍显示上一个账号的内容。
- **根因**：界面启动时只 `reload_snapshot()` 读上一次落盘的旧 JSON，没有先跑刷新编排；旧快照不会自动过期。
- **修复**：
  - 启动即触发一次后台 `refresh_all()`，状态栏显示采集时间（`uia_cards.json` 的 `captured`），刷新完成后重绘。
  - `uia-collect.py` 窗口选择改为：收集所有在进程内且未离屏的 `page-profile` 候选，按可见面积排序取最大，避免捡到残留的旧主页窗口。
- **实测**：切换到新账号后重采，UIA 读到新网格 8 张（与旧账号 15 张不同）；新账号尚未 hover，主进程无对应流键，解析为 0 ready/pending 属正常——hover 取流后再刷新才会配对。
- **结论**：无需切回原视频号；界面跟随当前微信里可见的主页窗口。旧账号已下载记录保留在 `library2.json`，切换账号不清除。
- 遗留：新账号多条卡片 UIA 文案为空（时长/点赞可读），属 UIA 文本读取限制，后续可单独优化。

### 16.21 hover 后仍全 pending 的内存归因

- **取流状态确实变化**：hover 后主进程 40512 扫到 39 条配对（37 条 20302 + 2 条 20304），出现新账号 oid；流键/URL 已进主进程，并非完全没取流。
- **绑不上的三层原因**：
  1. **元数据未解出**：配对要靠邻近窗口解码 recsys blob 拿到 `vid_len/like`，才能和 UIA 时长+点赞对齐。当前只有少数记录解出（如 214/21981、358/7767）；同一条 oid 两次扫描间 meta 可能被回收（179/5736 那次解出、下次为 None）。
  2. **renderer 堆对不上**：6 个 renderer 中仅 26772/43456 有解码记录，但其 vid_len/like 属于别的推荐列表，与当前主页 8 张卡片时长均不匹配；当前主页模型记录在堆内不可直接字符串归因。
  3. **URL 残缺/混拼**：部分配对只截到短引用（无 `sign/basedata`），CDN 拒 400；偶发多片段混拼出不一致 URL，参数看似齐全仍 400。
- **已落地修复**：
  - `main-pair.py` 同一 oid 保留参数最全的 URL（参数数更多者覆盖短引用）。
  - `card-resolve.py` 缺 `sign/basedata` 的配对不落 ready，记 `note`；`wx-viewer.py` 失败回执新增 400 归类“流地址失效或残缺，重新悬停取流”。
- **实测对照**：1505244…（214s/2.1万）meta 解出、对齐 ready，但 URL HEAD 400；1505316…（179s/5736）URL HEAD 200 存活，但本次 meta 未解出，未绑定。
- **后续方向**：扩大主进程邻近窗口/校正记录边界提高 blob 解码率；跨进程合并同 oid 的完整 URL；下载前 HEAD 预检，400/401 直接标失效不进下载流程。

### 16.22 三期：Python 下载解密引擎落地

- 新增 `tools/dl_engine.py`，忠实移植 `wx-dl.ps1` SaveUrl 链路：
  - HEAD 取 `X-enclen`/Content-Length，enclen 越界回退 131072；403/401 判过期。
  - requests 直连（`trust_env=False`，等价 `--noproxy '*'`）流式下载密文。
  - ctypes 扫 WeChatAppEx（RSS>60MB，按工作集降序）已提交私有可读内存区，找 `ftyp` 后 4 跳内出现 `moov` 的明文头；按头 MD5 去重。
  - `Test-Mp4Layout` 虚拟视图闸门：首盒 ftyp、必须有 moov/mdat、moov 不得大于整文件、`declaredEnd` 与密文长度差 ≤ max(1024, size*0.0002)。
  - ffprobe 时长闸门（与 ExpectedDuration 差 >3s 跳过）；ffmpeg `-t 3` 探针 + 全片解码，良性噪声正则 `non monotonically increasing dts|Application provided invalid` 不计错。
  - 拼接头+密文尾，按 `视频号_yyyyMMdd_HHmmss_{h}p_{dur}s.mp4` 落盘；CLI 契约 `SAVED=<path>` exit 0 / `FAILED` exit 2。
- `wx-viewer.py` DownloadWorker 已从调 `wx-dl.ps1` 改为调 `dl_engine.py`（`sys.executable`，前置 ffmpeg 目录，`PYTHONUTF8=1`）；失败回执补“未打开视频号窗口/时长不符/未过解码校验”等归类；移除旧 pwsh 调用。
- **验证**：对存活 URL 端到端跑通（HEAD→下载 26.7MB→扫到 3 个候选头→结构闸门判错拒绝→FAILED exit 2）；对已存样本 MP4 跑闸门 ok、declared 与文件长度一致、ffprobe 时长与文件名吻合、全片解码 0 真实错误。
- **未闭环**：本会话尚无“Python 引擎真实下载成功”样本；待下一条可绑定且内存头在位的卡片实跑确认。代理快照/设置/还原与 mitm 自动抓包模式未迁（新界面不走代理），列入任务 #10。

### 16.23 renderer 堆聚合修复绑定；悬停态缺明文头仍是下载瓶颈

- **问题**：refresh 后界面全 pending。日志显示主进程 40 条配对里仅 5 条解出 meta（且都是同一条 116s/2011 的旧缓存），其余 `len=None`，无法按时长对齐；`mem_model2.json` 是旧账号残留，流水线此前不重扫 renderer。
- **修复**：新增 `tools/mem-render.py`，枚举所有 `--type=renderer` 的 WeChatAppEx（本次 6 个），扫描 nonceId 后 base64 recsys blob 解码，按 object_id/nonce 合并去重落盘 `mem_model2.json`；`refresh.py` 插入“renderer 模型聚合”步骤，位于主进程配对之后、回表解析之前。
- **效果**：15 张卡片命中 10、ready 10、点赞一致 10；10 条 ready URL 逐个 HEAD 实测全部 **200** 存活。
- **下载瓶颈定位**：对 idx0（242s/1.8万，URL 200）实跑 Python 引擎，密文 26.7MB 下载完成，但全进程诊断（`diag-heads.py`）只在 renderer 43252 找到 4 个明文头：两个声明 103119/89396 字节（别的短视频），两个无 mdat；主进程 40512、xplayer 39292、其余 renderer 均无 ftyp 头。**目标视频的解密 MP4 头不在内存**，闸门正确拒绝了外来头，FAILED。
- **结论**：hover 只预取加密流，解码器未把该卡片的明文头常驻内存；明文头通常要在预览/播放实际解码后才出现。引擎侧已与 MemScan.cs 对齐：只扫 MEM_PRIVATE 已提交可读区、前缀按 enclen 长度 dump、整段头 MD5 去重。
- **待验证动作**：在微信里点开/播放某条 ready 卡片几秒（让解码器保留明文头），再回界面点下载；若头在位，引擎应能走通拼接→时长闸门→全片解码→落盘。
- **修复**：`mem-render.py` `parse_url` 的键未按 UTF-8 容错解码，遇到内存里混入的 0xbd 等非法字节抛 `UnicodeDecodeError`，导致“renderer 模型聚合”步骤失败、界面刷新报错；已改为键值都 `decode("utf-8","ignore")`。重跑流水线绿，18 卡 ready 11、点赞一致 10，ready URL HEAD 多为 200。

### 16.24 下载中残留、孤儿进程与中间文件清理

- **现象**：关闭 viewer 后多条记录卡在“下载中”；日志/库中一条报 `调用异常: embedded null character`。
- **根因**：① 内存取出的 URL 混入 NUL/控制字符，拼进 subprocess 命令报 embedded null；② 界面退出时阻塞在 `subprocess.run` 的下载子进程没被收口，成了孤儿继续下载；③ 上次退出未回填的 `downloading` 状态被界面一直沿用；④ 失败/中断的 cipher/cand/prefix 中间文件长期堆积。
- **修复**：
  - `wx-viewer.py` 新增 `clean_s()` 剥离 NUL/控制字符，下载前清洗 URL 与 tag；worker 内二次清洗。
  - 启动时把残留 `downloading` 记录回退为 `pending`；`_merged_status` 只认 done/failed，不再沿用 downloading。
  - `dl_engine.py` 入口清洗 URL；新增 `_cleanup()`，下载失败/过短/校验未过/成功后清理 cipher/candidate 中间文件。
  - 现场处置：杀掉 2 个孤儿 dl_engine 进程；重置 7 条卡死记录；清理 60 个中间文件共 367MB。库现状：done 5 / failed 4 / pending 7，无 downloading。
- **遗留（任务 #11）**：关闭界面时主动终止活动 worker 及其子进程（Popen 持 PID 或 Job Object 托管），避免再次产生孤儿。

### 16.25 CPU 飙高：孤儿下载引擎/扫描进程

- **现象**：CPU 被打满。当前 CPU 采样发现 7 个 `dl_engine.py`、1 个 `mem-render.py`、1 个 `refresh.py` 各占约 100% 单核，均为之前关闭 viewer 后残留的孤儿进程。
- **根因**：① 关闭界面时阻塞在 `subprocess.run` 的下载子进程没被收口，随 viewer 退出后继续跑；② 多次点击下载会并发拉起多条引擎；③ 内存扫描/解码本身是 CPU 密集型，多进程并发把多核占满。
- **处置**：已结束全部 9 个项目孤儿进程，系统 CPU 回落到 2%；保留无关的其他项目 python 进程。
- **已加防护**：viewer 下载并发上限改为 1（已有一条进行中时拒绝再点）。
- **遗留（任务 #11）**：closeEvent 里终止活动 worker 及其子进程；DownloadWorker 改用 Popen 持 PID，退出时可强杀子进程，避免再次残留。
- **已落地（#11 完成）**：DownloadWorker 改用 `Popen` 持子进程句柄，新增 `kill()`（terminate→3s 未退则 kill）；Viewer `closeEvent` 遍历所有下载 worker 调用 `kill()`，关闭界面时收口下载子进程，不再留孤儿。

### 16.26 标题空值修复、操作指南与 hover 配对差分

- **标题空值根因**：`uia-collect.py` 原只遍历 click-box 的直接子节点 Text，嵌在后代层级的文案被漏掉；18 张卡片有 7 张 desc 为空。改为 `TreeScope_Descendants` 后代遍历后重采，18 条文案全部恢复。
- **当前快照**：18 卡 ready 10 / pending 8，点赞一致 9。
- **ready ≠ 落盘**：ready 只表示 `object_id ↔ 完整签名 URL` 配对且 HEAD 存活；真正落盘还需该视频在 WeChatAppEx 内存留有解密明文 MP4 头。hover 多只预取加密流，明文头通常要实际播放/解码后才常驻。
- **hover 后界面不变的归因**：新增 `tools/pair-diff.py` 对比两次扫描的主进程+renderer 配对集合。无操作连扫两次即有 5 条新 oid 进主进程、0 消失，但这些新记录 `len=None/like=None`（邻近窗口 base64 未解出 meta），无法按时长+点赞对齐到卡片，界面仍显示 pending。即瓶颈在主进程邻近窗口 meta 解码率与跨进程 meta 合并，而非取流本身。
- **产物**：`docs/usage-guide.md`（状态含义、标准下载 SOP、失败原因对照、数据流、已知限制）；`work/pair_baseline.json` 配对基线；`tools/pair-diff.py`（`--save` 存基线，默认对比新增/消失/变化）。
- **遗留方向（任务 #12）**：提高主进程邻近窗口 recsys blob 解码率；跨进程（主/renderer/CEF/网络）同 oid 合并完整 URL 与 meta；明确“重播取头”操作路径在界面上的提示。

### 16.27 多账号 profile 层堆叠：采集跨层合并导致拿到非当前视频号

- **现象**：启动 viewer 拿到的不是当前微信里打开的视频号内容；历史快照里混入了别的账号的卡片和文案。
- **实证**：AppEx 主进程 40116 内 `page-profile` 层有 3 个，矩形/离屏标志完全相同，分别对应不同账号：`清一色-幽默油条喜剧`(45 卡)、`杠京-北京杠爷`(60 卡)、`nice摄影`(30 卡)。微信只保留最近打开的页面在前台，历史账号页面作为隐藏 DOM 层仍留在同一窗口内。
- **根因**：旧 `uia-collect.py` 选中顶层 AppEx 窗口后，在**整个窗口后代**里枚举 `click-box`，把 3 个层的卡片合并到一张表；层选择只按面积排序，并列时取到错误层。
- **修复**：
  1. 先枚举所有 `page-profile` 层及其账号名/卡片数；
  2. 活动层判定顺序：焦点元素祖先 → 视口中心点 `ElementFromPoint` 命中祖先 → 卡片最多的层兜底；
  3. 卡片只在活动层内枚举，不再跨层合并；
  4. 快照新增 `account` 与 `layers`（各层账号名/卡片数），界面顶栏显示当前账号。
- **验证**：重采后隔离到 `杠京-北京杠爷` 一层 10 卡；全链路 refresh 绿色，10 卡 ready 10、点赞一致 9。
- **遗留**：焦点/命中都拿不到时（微信窗口被遮挡）兜底按卡片数选层，可能选错；`mem_model2.json` 仍跨 renderer 聚合，跨账号绑定防护归任务 #12。诊断工具 `tools/diag-layers.py`。

### 16.28 重启后仍显示旧账号：非进程残留，是 UIA 只序列化了缓存层

- **现象**：重启微信后 viewer 仍显示旧账号；用户当前打开的是 `nice摄影`，采集到的却是另一个缓存 profile `乖乖兔3311`。
- **进程排查**：所有 Weixin/WeChatAppEx 进程创建时间均为 19:09（重启后新建），旧 PID 40512/40116 已退出，**无残留进程**。
- **UIA 实证**：在全部微信窗口文本里检索 `nice摄影`/`摄影`/`nice` 均 0 命中；无障碍树里只挂着缓存的 `乖乖兔3311`（163 条原创内容、山东滨州女）。即当前前台页面尚未被序列化成 UIA 树，读到的是历史缓存层。
- **层间时间信号**：page-profile / wrapper 层没有时间戳字段；区分前台/后台只能靠焦点元素祖先或视口中心点 `ElementFromPoint` 命中。后台进程被 OS 前台锁拦截，`SetForegroundWindow` 抢不到前台（实测返回失败，前台仍为浏览器）。
- **结构修正**：父链实测 `click-box → content → page-profile → app-body finder-profile-wrapper → pcWechat multi-tabs`；`page-profile` 在卡片层有重复节点，按账号隔离应上溯到 `finder-profile-wrapper`。分组已改按 wrapper 归层。
- **前置条件（写入指南）**：采集/刷新前必须先把微信视频号窗口点到前台（在窗口内点一下），让当前页进入无障碍树；被浏览器遮挡时 UIA 读不到当前账号。

### 16.29 只采集到 1 张卡片：COM 代理 id 分组失效

- **现象**：账号选对后界面只显示 1 条，而 UIA 树里实际有 30 个 click-box，每张都带时长和文案。
- **根因**：上一版按 `id(COM 元素代理)` 把卡片归到 profile 层；comtypes 每次 `GetParentElement` 返回新的 RCW 代理，`id()` 不稳定，导致 30 张卡被拆成 30 个单卡组，活动组只保留 1 张。
- **修复**：改为按顶层窗口归层，活动容器确定后用 `FindAll(Descendants, click-box)` 在容器内统一枚举；卡片排序按卡片矩形中心行/列归位。
- **验证**：当前视口 10 张卡全部读出（两行×五列），刷新绑定 ready 4、点赞一致 4；视口下方未滚动到的卡片受容器矩形裁剪，属正常。

### 16.30 hover 取流链路实测：信息已收到并成功绑定

- **操作**：用户在视频号主页 hover 若干卡片后重扫内存。
- **内存信号**：主进程/renderer 出现新的 oid↔20302 完整签名 URL 配对；多条记录解出 vid_len/like，时长点赞与当前卡片对得上。
- **绑定结果**：重绑后快照 9 张卡全部 ready，点赞一致 9/9；说明 hover 取流 → 主进程配对 → renderer meta 对齐 → 卡片 ready 这条链路是通的。
- **基线**：`work/pair_baseline.json` 已重置为 hover 后状态；下次 hover 再跑 `pair-diff.py` 可干净对比新增/消失。
- **遗留**：本次 UIA 重采少了一张（00:29/10），属视口/滚动变化；下载落盘仍卡在明文头是否常驻内存（任务 #9）。

### 16.31 第 0 步：按账号持久化的 slot 注册表

- **设计目标**：界面先于下载建立稳定槽位；同一视频号内刷新只做“对照回填”，可取流/可下载/已下载状态跨刷新保留；换视频号才重置。
- **落地**：
  - 新增 `work/slots.json`：`{account, updated, slots[]}`，槽位字段含 object_id/nonce/desc/duration/seconds/like/url/status/file/error/seen/last_seen。
  - 主键：有 `object_id` 用 `oid:<id>`；没有时退化为 `txt:<seconds>:<文案指纹>`，后续解出 oid 时再按 oid 反查归并。
  - 刷新合并：快照卡片匹配到旧槽位则回填文案/时长/点赞/url/oid；下载终态（done/failed）与进行中（downloading）不被快照覆盖；不在当前快照的旧槽位保留并标记 `seen=False`。
  - 账号判定：UIA 账号名变化才清空槽位；账号读空时沿用旧账号，避免一次采集失败清空。
  - 采集器解析头部 `N条原创内容` 写入 `total_count`，界面显示“共 N 条 / 已发现 M / 可取流 K”。
- **验证**：offscreen 实例化 viewer，9 条槽位落盘；二次加载无重复；total_count=163 正确读出。
- **后续**：翻页后增量并入槽位；是否为总数预留空占位槽位待定（空槽无身份指纹，易互相碰撞，暂不建）。

### 16.32 翻页后槽位不更新与重复滞留

- **现象**：翻页后界面列表不变；快照对比：首屏 UIA 10 条，翻页后一次 refresh 日志读到 20 条（前 10 + 后 10），resolved ready 15、点赞一致 15，说明后端读取随翻页更新。
- **发现的槽位 bug**：同一卡片两次采到的 object_id 不一致（旧槽 `1501462…`、新配对 `1505544…`），按 oid 匹配失败，旧槽滞留为 `seen=False`，新槽追加，导致 20 条快照变成 21 行重复。
- **修复**：匹配链改为 `oid 主键 → oid 反查 → 时长+文案指纹兜底`；保留旧槽已稳定的 oid，快照没解出 id 时不覆盖。清空重复槽位后重载，20 条无重复。
- **机制说明**：视频号列表是虚拟化渲染，DOM 只保留已加载卡片；总数 163，随滚动/翻页新枚举到的卡片会增量并入槽位，不在当前快照的旧槽保留展示。

### 16.33 uia_dump 来源澄清：UIA 树，不是内存堆

- `tools/uia-dump.ps1` 通过 UIAutomation 遍历顶层窗口的**可访问性树**（FindAll Children 逐层走 DOM 暴露给辅助功能的节点），不是读进程原始内存堆。
- 样本 `uia_dump_20261116_133159.json`：元素总数 360，其中时长文本 60 → 当时树里驻留 **60 张卡片**；账号“杠京-北京杠爷”，头部标注 433 条原创内容。即树里只保留当前已加载/已渲染批次，**不是全量 433/163**。
- 另一类来源 `mem_model2/main_pairs` 才是扫进程私有内存里的缓存字符串/V8 记录；数量虽多（mem_model2 218 条），也是已抓过的 feed 缓存与历史/广告残留，不保证等于当前账号全量。
- 全量列表只能靠：① 滚动/翻页触发分页加载后增量并入；② 原生 feed cgi（6624/9586）整页响应（任务 #4/#12，未打通）。

### 16.34 feed cgi 逆向结论与序号占位槽位

**前端协议实证（js-ref/profile.publishVsbV6VmmuS.js + virtual_svg 大 bundle）**：
- 作者主页接口 `finderUserPage`，请求体：`{username, objectId, finderUsername, lastBuffer, needFansCount, sessionBuffer, finderBasereq}`；分页游标 `lastBuffer`，结束标志 `continueFlag===0`。
- 响应体：`object[]`（卡片模型）、`lastBuffer`、`continueFlag`、`originalInfo.originalCount`（原创总数）、`contact`、`fansCount`、`bizInfo`。
- API 表：`FinderUserPage` → pc `/cgi-bin/micromsg-bin/pc_finderuserpage` cmdid 6624；另有 ilink 变体 `ilink_finderuserpage`。
- **传输通道**：`post → invoke → window.WeixinJSBridge.invoke("finderH5ExtTransfer", {url, data})`，由原生主进程代发 MM 协议；不是可直接复放的公网 HTTP。外部 Python 复放需要会话 token/鉴权与原生桥，当前无 CDP 端口、DB 加密，复放路径未打通（任务 #4 维持 pending）。

**落地的顺序核对方案（不依赖 cgi）**：
- 总数已能从 UIA 头部 `N条原创内容` 读到（`total_count`）。
- viewer 按总数预留空占位行并加序号：真实槽位按发现顺序编号；占位行 `placeholder=True`、不入库、无身份指纹、不可下载，状态“待加载”。
- 实测：当前 15 条真实槽位 + 占位补到 163 行；序号列 1..163，尾部占位行为空。
- 限制：未翻到的卡片位置只是“按总数预留”，真实 feed 顺序要随滚动并入后才能逐行核对；历史未在当前页的旧槽位保留在真实槽位区，后续可加分组/筛选。

### 16.35 参考只读项目 D:\GitHub\wx_video_downloader 的全量列表方案

**只读参考，未写入该目录。** 其 `prototype/` 已跑通“完全列表”：
- `uia_paginate.py`：定位活动 `page-profile` → 读当前批次 click-box → 鼠标滚轮逐屏翻页 → 按 `时长|点赞|文案` 指纹增量合并 → 连续两页无新增停止 → 结束回顶。
- 同账号“乖乖兔3311”实测：头部标注 **163 条原创内容**，顺序滚到底去重后 **330 张 / 33 页**。
- **口径修正（推翻 §16.34 的 163 占位假设）**：163 是“原创声明且审核通过”的作品数，不等于主页作品总数；330 = 原创 + 未声明原创 + 图文/图片动态/直播回放等。不能拿 163 截断或预留空槽。
- 封面：UIA 不暴露图片二进制，只能按 cover 矩形 `ImageGrab` 截屏缓存（md5 指纹命名）；采集时微信须前台、viewer 不能遮挡卡片区。

**可复用并已移植到本项目**：`tools/uia-paginate.py`（沿用本项目 wrapper 祖先层隔离 + 焦点/中心点兜底选层；输出字段与 `card-resolve` 兼容；`--no-scroll/--no-restore/--max-pages/--wait`）。定位：一次性“全量同步”，**不进 15s 自动刷新**（否则每次刷新都滚动微信）。

**参考项目自身仍未解决的问题（本项目同样存在，勿重复踩）**：
- URL↔卡片仍是候选里“猜”：预加载下一条/上一条同在 recentMedia，MaxEnd 更大不保证是目标；
- 明文头只在**实际播放/解码后**常驻内存，没播放过的视频没有头可用；
- URL token 会过期，本地缓存 URL 只能短期复用；
- 指纹（时长+文案）在重复时长/重复文案时会误合并；
- 同时长多清晰度/多文件头，只能靠头 MD5 区分；
- 代理抓不到目标 URL 时，内存扫描是兜底。

**后续接线**：viewer 加“全量同步”按钮 → 后台线程跑 `uia-paginate.py` → 结果并入 slots；快速刷新仍走 `uia-collect.py`。

### 16.36 viewer 全量同步接线（任务 #17）

- 顶栏新增「全量同步」按钮；`FullSyncWorker`（QThread）后台跑 `tools/uia-paginate.py --out work/uia_paginated.json`，日志写 `work/paginate.log`，超时 600s。
- 与自动刷新互斥：采集中禁用「刷新/全量同步」，`refresh_all` 检测 `_syncing` 直接返回。
- 完成后 `_merge_paginated()` 把分页卡片转成行记录，按 oid/指纹并入 `self.slots`（保留下载终态），再 `reload_snapshot()` 渲染；分页结果不带流 URL，状态先置 pending，后续悬停刷新再回填 ready。
- 合并逻辑抽成 `_merge_rows(rows)`，快照刷新与全量同步共用；序号列/状态列/下载按钮列已对齐为 0 序号、1 状态、5 按钮。
- 实测：合成两张分页卡片并入 72→74，指纹/oid 匹配路径正常；测试残留已清。
- 遗留：关闭界面时 RefreshWorker/FullSyncWorker 的子进程未像 DownloadWorker 那样持句柄强杀，极端情况下可能残留一个短生命周期采集子进程，后续收口时补。

### 16.37 Python 引擎首次真实落盘成功（任务 #9 突破）

**结论：三期 Python 引擎端到端跑通，已落盘 2 个经 ffprobe/全片解码校验的成品。**

- 新鲜管线实测（账号「杠京-北京杠爷」）：UIA 10 卡，命中配对 8，ready 8，点赞一致 4；ready 卡片 URL 均带 `sign=`+`basedata=`。
- **配对关键信号：整文件大小**。HEAD 取 `Content-Length`，与内存常驻明文头解析出的 `declared`（mdat 声明总长）比对，容差 `max(1024, 0.02%)`。实测两个常驻头：6,184,237 / 5,236,922 字节，分别精确命中两条流的 Content-Length。
- 成功样本 1（当前页卡片，可与 UIA 对应）：oid `14384963291671300421`，卡片 00:55 → 成品 `视频号_20261116_235353_576p_56s.mp4`，6,184,237 字节，hevc 576×1024 + aac，时长 55.67s，全片解码 0 错误。
- 成功样本 2（当前页外、主进程配对）：oid `14945257653624047931`，成品 `视频号_20261117_000339_576p_36s.mp4`，5,236,922 字节，hevc 576×1024 + aac，时长 35.94s，全片解码 0 错误。
- **引擎改动**：下载密文前先预扫常驻头并缓存（pid/addr/header/declared）；HEAD 大小与常驻头声明长度早筛，对不上直接报「内存无对应明文头，请播放/悬停几秒后重试」，不再先下整条密文再失败。候选头按整段 MD5 去重，结构闸门 → ffprobe 时长 → 前 3s 解码 → 全片解码逐级校验。
- **仍受限于头驻留条件**：明文 MP4 头只有视频被实际播放/解码后才常驻 WeChatAppEx 内存；仅 hover 预取加密流不一定产生明文头。未播放过的视频早筛会被拦下，这是当前唯一绕不开的前置条件。
- 待办：`work/` 下残留旧 PS1/早期引擎的 `cipher_*.bin / cand_*.mp4 / prefix_*.bin` 共 66 个约 1.1GB，均为可再生中间文件，可在确认后统一清理。

### 16.38 work 目录代码归档

- `work/` 只保留数据快照/日志/中间产物；早期一次性探针脚本全部移到 `tools/legacy/`（27 个），按内存探针 / 配对对齐 / 本地库排查 / 成品解析 / 旧 HUD 原型分组，见 `tools/legacy/README.md`。
- 删除两个无逻辑脚手架 `tiny.ps1 / tiny2.ps1`。
- 活跃管线脚本仍在 `tools/` 根目录，界面 `wx-viewer.py`；归档脚本不被任何活跃代码调用，复跑前需校正硬编码/相对路径。

### 16.39 能否本地拼接 URL / 借 WeixinJSBridge 生成 token

**结论：现状下都不能。**

- **URL 拼接实测**（同一条 200 流）：完整原始 URL `200` / len 4,196,919；只留 `encfilekey/m/token/uzid/idx` 自拼 `400`；去掉 `sign/svrbypass` 其余保留 `400`。`sign`、`svrbypass` 是服务端按会话/请求签发的防重放参数，本地无密钥与算法；`token/encfilekey` 短时有效、随会话/码率轮换，过期不可复用。正确做法是取流当下把 `主键 ↔ 完整原始 URL` 成对捕获落库，原样使用，不用稳定 id 反推或重签。
- **WeixinJSBridge 定位**：原生壳注入 finder renderer H5 `window` 的代理对象，`finderH5ExtTransfer` 由原生主进程接管转 MM 协议；它不在 JS 内铸签名/token，`encfilekey/token/sign/svrbypass` 是后端/CDN 返回。
- **调用通道排查**：renderer 命令行无 `--remote-debugging-port`；主进程本地监听 14013/16/19/22/23 端口，`/json/version` 均非 HTTP CDP（20808 是系统代理）；UIA 只能读无障碍树、不能执行 JS；自定义 H5 无 finder 特权上下文与鉴权；业务库 SQLCipher 加密、未取到会话密钥。
- **理论突破方向（成本高、不确定）**：① 包装重启微信给 AppEx 注入调试端口（release CEF 可能禁用 DevTools，且须在正确 finder 页面上下文调用）；② 逆向原生 MM 协议 / 提取 SQLCipher 密钥本地复放 6624 等 cgi。现阶段仍走被动捕获原生已产出的完整 URL，配对后趁新鲜下载。

### 16.40 绑定对不上的现场实证与分层方案（任务 #12）

**现场快照（账号「杠京-北京杠爷」，UIA 15 卡）**：
- 主进程 `main_pairs.json`：17 条 `oid ↔ 完整 URL`，其中 **15 条 meta 为空**（无 vid_len/like）。
- renderer `mem_model2.json`：89 条记录，仅 39 条带 `vid_len`，且其 oid 与主进程配对 **零交集**（直接/16 位后缀均不命中）；时长/点赞也对不上当前 UIA 批次，多为历史缓存；多数未挂 20302 键。
- `card-resolve.py` 只按 **oid 单键**把 renderer meta 接到主进程配对：oid 找不到 → len/like 全空 → `by_len` 空 → 全部 pending，本轮 `matched 0 / ready 0`。

**断裂本质**：Card 侧 UIA 不暴露机器主键；流侧 oid+URL 在主进程、meta 在 renderer，两边又不在同一批记录。单边/单信号（时长/顺序/大小/点赞）必然踩到预加载邻条或历史残留。

**分层锚点（强度从高到低）**：
1. 同记录直绑：同一内存记录窗口内同时拿到 oid+时长+点赞+20302/20304/20350 键（理想态）。
2. oid 跨进程归并：主进程 oid↔URL 与 renderer oid↔meta 按 oid（16 位后缀归并）+ encfilekey/m 双键补全；须在当前页加载/悬停当下抓，不扫历史缓存。
3. 复合对齐 UIA：时长精确 → 点赞就近 → 封面图比对（UIA 封面截屏 vs 20304 封面字节/hash）→ 列表顺序兜底。
4. 置信度闸门：快照记录命中了哪些信号；只有强锚点开放下载，弱匹配标灰。

**待补缺口**：① 50 条非ce-only renderer 记录为何 blob 未解码（窗口/记录边界/UTF-16/protobuf 切片）；② card-resolve join 扩成 oid 后缀 → encfilekey → m 多级回退，renderer 索引按 oid/nonce/键共建；③ 封面截图与 20304 封面 hash 消歧；④ 抓取时机限定当前可见批次，不跨历史池猜。

**边界**：Card 侧不暴露 oid 时不存在 100% 单信号对应；只能复合锚点 + 置信度闸门，预加载干扰靠同记录窗口绑定 + 当前批次对齐规避。

### 16.41 DSH（只读参考项目）按需激活方案复盘

**流程**（`viewer/wx_viewer.py` ActivateWorker）：扫描全量卡片 → 点下载 → 已绑 oid 先重扫主进程取新 URL，未绑则建基线配对 → UIA 定位卡片 → hover 2.2s → 扫主进程与基线 diff 新增 → `_choose` 按 `meta.vid_len` 就近挑；挑不到则 invoke 播放、等 2.5s 再扫再挑 → Esc 关播放器 → curl HEAD 预检 → pwsh `wx-dl.ps1` 落盘（结构/时长/解码终校）。

**效率低（代码实证）**：
- 主进程全量内存扫描单次约 46s（源码注释自承），每张卡最多扫两次（hover 后 + invoke 后），另有一次基线扫描。
- 每张卡重做 `_init_uia/_pick_profile/find_card`，找不到滚动重试 8~18 次；固定等待 hover 2.2s+0.8s+invoke 2.5s+关窗 0.4s。
- 串行单卡、界面阻塞；下载侧再起 pwsh 引擎并内部复扫内存头。

**成功率低（分层）**：
- 配对仍是猜：`_choose` 主要靠 meta 时长就近，meta 常空则 diff=99999；多条完整 URL 时仅"唯一且差≤3s"才接受。基线 diff 假设新增即目标，但内存留历史/广告/预加载邻条；hover 命中本地缓存不发请求时无新增对。播放器自动连播时"只有一条取流"不成立（known-issue #13）。
- 明文头时机无保证：invoke 后仅等 2.5s 就关播放器，头未必常驻；头扫描有 8s 截止，目标头靠后可能被跳过。
- URL 时效：长扫描+多步等待间 token 过期，HEAD 400/403，重试仍用旧 URL。
- UIA 定位不稳：key=时长|点赞|文案，文案截断/重复时长/重复文案 → 找不到或多条歧义。
- 错配被终校拦下表现为失败；邻条时长接近时仍可能下错（known-issue #1）。

**可借鉴**：按需激活单卡强制取新流/新头；基线 diff 隔离新增流；保留结构/时长/双段解码终校；封面截图作消歧锚点。
**应避开**：全量主进程扫两次/张；就近时长单选当绑定；关播放器后才确认头；陈旧 URL 重试；文案指纹当稳定主键。

**融合到本项目的方向**：绑定优先同记录 oid↔URL，renderer meta 按 oid/键补全，补不齐不亮下载；需取流时再激活，播放器保持打开，增量扫到新 oid↔URL + 明文头（大小+时长+头 MD5）确认后再下载；内存扫描只走当前 profile 进程并缓存增量；时长+点赞+封面 hash 复合消歧，歧义标灰；下载前瞬间 HEAD，400/403 重新激活而非重试旧地址。

### 16.42 读内存还能再走几层（应用层堵死后的评估）

**第 1 层（已到）：字符串邻接扫描**
- 主进程：`object_id ↔ 完整 stodownload URL` 相邻；renderer：`nonce ↔ base64 recsys blob ↔ 20302/20304/20350 URL` 相邻。
- blob 字段全集（遥测/推荐上报）：`object_id/vid_len/cur_like_count/cur_comment_count/feed_pos/tab_feed_pos/page_num/scid/aid/request_id/ad_*`，**不含文案/昵称/媒体 URL**；文案作者只在 UIA。

**第 2 层（性价比最高，纯字符串层可马上做）**
- blob 里的 `feed_pos/page_num/scid/aid/request_id` 目前 card-resolve 未使用；抽出落库后用「位置顺序 + 时长 + 点赞」复合对齐 UIA。
- 跨进程按 `encfilekey/m` 把主进程 URL 与 renderer meta 并到一条；主进程 8000 字节窗口放宽，尝试邻接 UTF-16/UTF-8 中文文案/昵称。
- 现场实测：当前堆里 39 条带时长记录分属两个旧会话（oid 1425… / 1498…1500…），时长点赞与当前 UIA 批次对不上——位置锚点只在当前页记录被当下捕获后才有效，旧缓存不能回表。

**第 3 层（硬绑定彻底解，成本高）**
- 3a V8 堆对象图遍历：从字符串引用追到 JS 对象槽位，同一对象内同时取 desc/nickname/oid/media URL；难点是 V8 指针压缩与对象布局随版本变，需逆向 renderer 堆格式。
- 3b 原生主进程 protobuf / DB 密钥：feed cgi 响应 protobuf 内 object_id+media+meta 同消息；或从内存提取 SQLCipher 密钥解缓存库；难点是 protobuf schema、密钥提取、加密段。

**内存走不出去的边界**：`sign/svrbypass` 只有服务端签好的副本，不能重签，过期只能重新取流；不能靠内存调 WeixinJSBridge/原生桥；明文头必须实际播放解码后才存在，扫描只读取不制造；历史/广告/预加载残留不会消失，绑定必须限定当前批次。

**建议**：先做第 2 层（位置字段接入回表 + 跨进程键合并），实测当前页对齐率；再评估是否上第 3 层 V8 对象图或 protobuf。

### 16.43 突破：renderer 堆内三类结构化卡片记录（第 2 层落地）

**实证发现**：当前主进程 oid 确实在 renderer 堆内（探针 `tools/probe-oid-renderer.py`），且以三种此前正则未覆盖的结构化形态存在：

1. **VNode 卡片串**：`finder-profile-card,{"feedId":"<oid>";"cols":n;"index":i}` —— 直接带网格序号 `index`。
2. **ele_info**：`"feed_id":"<oid>","session_buffer":"<base64>"` —— base64 解码为 recsys JSON，含 `vid_len / cur_like_count / feed_pos / scid / object_id`。
3. **邻近对**：`<oid>,https://.../20302/stodownload?...` —— oid 与流 URL 同记录相邻。

**对齐验证**（`tools/probe-align.py`，当前账号「杠京-北京杠爷」15 卡）：
- idx11 91s/2118、idx10 29s/843、idx5 34s/3711：序号✓ 时长✓ 点赞✓；
- idx6 29s/2.1万、idx1 55s、idx7 194s/4860、idx3 178s/2.9万、idx2 42s/250：时长✓ 点赞✓（部分缺序号）。

**落地改动**：
- `tools/mem-render.py`：新增 CARD/ELE/PAIR 三类正则，按 oid 合并序号/解码 meta/邻近 URL；保留旧 nonce+blob 路径兜底；URL 缺 scheme 前缀时补全 `https://finder.video.qq.com/251/20302/stodownload?`。
- `tools/card-resolve.py`：renderer 索引扩出 index/pos/scid/aid/url；对齐先比网格序号、再比时长（必须精确相等）、点赞二次校验；主进程 URL 残缺时回退 renderer 邻近 URL；renderer 独有且自带 URL 的记录补入候选池；按后缀归并截断 oid 副本，避免同一 oid 被当歧义双候选。
- 实测一轮：15 卡 **命中 10 / ready 10 / 点赞一致 9 / 序号一致 9 / 歧义 0**；抽 4 条 ready 流 Range 预检均 206 video/mp4 带总长。

**关键结论**：
- `encfilekey / m` 按流会话轮换，主进程与 renderer 全文零交集，**不能作跨进程稳定主键**；稳定主键仍是 oid。
- 结构化记录在 renderer 内已把 `oid + 序号 + 时长 + 点赞 + URL` 绑在同一邻接窗口，无需 V8 对象图遍历即可完成当前批次对齐；这是第 2 层能拿到的硬绑定。
- 未命中的 5 卡（108s/1689、46s/717、63s/1957、124s/3692、102s/424）在堆内尚无记录，对应未悬停/未播放条目；明文头与新 URL 仍需当下取流后才出现。

**遗留**：文案/昵称仍只在 UIA；session_buffer 不含 desc；跨账号/翻页后旧会话残留记录需靠序号+时长+点赞复合排除；renderer 独有记录的 URL 时效仍受 token 轮换限制。

### 16.44 激活实验：hover 长停即可常驻明文头；首条 viewer 链路前置验证落盘成功

**实验设计**：账号「杠京-北京杠爷」15 卡，先扫常驻明文头基线，再对基线中**没有**对应头的 idx6（00:29 / 2.1万，流总长 4,196,919 字节）在封面悬停 8 秒后复扫对比。

**基线常驻头（去重声明长度）**：118409 / 135025 / 148437 / 4156191 / 4317531（idx5）/ 5847745 / 10698624（idx11）。

**悬停后复扫**：
- 新增 **4,196,919**（= idx6 流总长，精确相等）、5,541,982（= idx12）、2,753,861（邻条/另一码率）、153346（小碎片）；
- 消失：118409 / 135025 / 148437 / 5847745 / 10698624。

**结论（推翻此前"必须点开播放器解码"的保守判断）**：
1. **仅 hover 长停约 8 秒，目标视频的明文 MP4 头就会常驻 `WeChatAppEx` 内存**，不需要点开播放窗口；
2. 明文头是有限缓存、会轮换淘汰，旧头随新头进入被挤出，下载必须在头仍驻留的窗口内完成；
3. 同屏邻条也可能被预取进头（2,753,861 / 5,541,982），配对仍必须走"大小精确 + 时长 ±3s + 解码校验"闸门，不能只看"有新头"。

**引擎直调验证（绕过 viewer，单独确认闸门与解密）**：
- 目标 idx6 oid `15047228709961992922`，HEAD 206 `bytes 0-0/4196919`；
- 引擎跳过唯一不配对候选：`声明总长 153346，密文 4196919，差 -4043573（别的视频的头）`；目标头通过结构/时长/双段解码校验；
- 落盘 `C:\Users\ASUS\Documents\视频号\视频号_20261117_015937_576p_29s.mp4`；
- ffprobe：**4,196,919 字节（与流总长精确相等）、hevc 576×1024 + aac、duration 29.000s**；抽 5s 帧为红衣小伙单杠+黑衣同伴悬挂+围观人群，与 idx6 封面/文案一致。

**对应关系三重核对通过**：字节数精确相等、时长精确相等、画面与封面一致。

**遗留（#18）**：上述落盘是引擎直调，尚未从 `wx-viewer.py` 界面点按钮走完；viewer 下载链路需补"下载前激活目标卡（hover 封面 ~8s 或轮询到头落位）→ 大小+时长对上后再调引擎"的环节，避免对未悬停卡片直接早筛失败。

### 16.45 viewer GUI 端到端首条成功落盘（#18 闭环）

**环境**：微信在线、视频号「杠京-北京杠爷」；viewer PID 48764（`wx-viewer.py`，Python 3.14）；常驻头所在 WeChatAppEx PID 47028。

**目标卡片（viewer 第 13 行 = resolved index12）**：
- oid `15036571014753487580`，时长 00:45，点赞 515；
- 文案「我们在公园表演老北京天桥绝活宫廷盘杠，受到观众们热烈欢迎！#宫廷盘杠 #单杠 #…」；
- HEAD 206 `bytes 0-0/5541982`；常驻头声明长度集合含 `5541982`（diag_heads.json）。

**操作链路（界面真实点击，非引擎直调）**：
1. 调试面板逐行核对 object_id 与 oid 一致后，才点该行右侧「下载」按钮；
2. 按钮矩形由 UIA 全表 dump 取得（x 1345–1426，第 13 行 y 591–620），换算 CU 坐标 (722, 561)；早期纯靠截图估行连续偏到第 11/12/14 行，证实**点按钮前必须用调试面板 oid 核对，不能按行号/估算坐标点**；
3. DownloadWorker 以 `dl_engine.py --url <流URL> --tag <oid> --expected-duration 45` 起子进程；引擎早筛大小 5,541,982 对上常驻头，过结构/时长/双段解码闸门后落盘。

**落盘与核对**：
- 文件 `C:\Users\ASUS\Documents\视频号\视频号_20261117_022428_576p_46s.mp4`，**5,541,982 字节（与流总长、常驻头声明大小精确相等）**；
- ffprobe：hevc 576×1024 + aac，duration 45.933s（卡片 45s，±3s 闸门内；文件名时长按 45.933 进位记为 46s）；
- 抽 5s 帧：公园绿色单杠架、两名男子立于软垫、围观人群，与封面/文案一致；
- library2.json 回填 `done`，记录 duration 00:45、like 515、file 路径；viewer 该行回填蓝色「已下载」，状态栏与调试面板显示保存路径。

**结论**：卡片 ↔ oid ↔ 流 URL ↔ 落盘文件的绑定在 viewer GUI 点击链路下首次端到端跑通，大小/时长/画面三重核对通过。

**本轮仍暴露的问题**：
- 自动刷新 15s 定时器在前台锁下拉起 `refresh.py`（主进程全量内存扫描约 46s），卡死界面并残留两组 refresh/mem-render 子进程（PID 38672/47788/55272/37804，已手动清理）；下载前应可停掉自动刷新，或把扫描改为非阻塞后台并限并发；
- 引擎早筛未配对时的失败原因串「内存无对应明文头…」未被 DownloadWorker 原因映射识别，回落成通用「下载失败」；需补子串匹配；
- 未悬停/头已淘汰的卡片（如 91s/2118，总长 10,698,624，头不在内存）早筛拦下，界面应明确提示「请在微信里悬停/播放该视频几秒后重试」，而非通用失败。

**本轮已落地的两处 viewer 修复**：
1. 原因映射补全（`wx-viewer.py` DownloadWorker）：新增「内存无对应明文头」→「内存无明文头，需重播/重悬停」、「文件过短」→「流数据过短，重新悬停取流」；原「内存里没有候选明文头」分支合并到同一提示。
2. 自动刷新默认关闭：全量内存扫描约 46s，远长于 15s 定时间隔，常开会持续后台重扫、挤占下载引擎；`auto_timer` 默认 unchecked、定时器不启动，需要时手动点「刷新」或勾选定时；`_toggle_auto` 仍可按需启停。启动时保留一次 `refresh_all()` 拉取当前快照。编译与 offscreen 实例化通过。
