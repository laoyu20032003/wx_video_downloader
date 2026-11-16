# UIA 卡片 ↔ 取流 URL 配对详解

> **DeepSeek Harness** · 文档整理与验证

> **来源与当前实现**
>
> 本文原为豆包调研文档；结论已落地到本仓库。
> - UIA 扫描：[../viewer/uia_scan.py](../viewer/uia_scan.py)
> - 主进程配对：[../viewer/main_pairs.py](../viewer/main_pairs.py)
> - renderer 模型：[../viewer/mem_render.py](../viewer/mem_render.py)
> - 绑定解析：[../viewer/resolve.py](../viewer/resolve.py)
> - 界面/下载：[../viewer/wx_viewer.py](../viewer/wx_viewer.py)
>
> 文中 `tools/main-pair.py` / `tools/mem-render.py` / `tools/card-resolve.py` / `wx-viewer.py`
> 是豆包原始工具名，对应本仓库的上述文件。豆包 package 不随仓库提交。

> 本文专门记录「界面上看到的一张卡片（封面/标题/时长/点赞）」如何与「它真正对应的那条加密视频流 URL」精确绑定，以及哪些字段能当主键、哪些不能。所有结论来自在线实测与本项目脚本实证，调研背景见 `association-research.md`。
>
> 一句话结论：**稳定主键是 oid（object_id / feedId）；时长是硬分组信号，网格序号优先、点赞二次校验；完整签名 URL 以主进程内存配对为准，renderer 堆记录补序号/时长/点赞；对不上的歧义条目直接拒绝，不靠流量顺序猜测。**

---

## 1. 整体链路

```
微信视频号主页（renderer 渲染的卡片网格）
   │  UIA 自动化树枚举可见卡片
   ▼
uia_cards.json          每张卡片：序号 index / 时长 seconds / 点赞 like_int / 文案 desc / 封面矩形
   │
   ├── main-pair.py  扫主进程 Weixin.exe 内存：oid ── 完整签名流 URL（20302）
   ├── mem-render.py 扫各 renderer WeChatAppEx 堆：oid ── 序号 / 解码 meta(时长·点赞·位置·scid) / 邻近 URL
   ▼
card-resolve.py         按 oid 回表 → 序号/时长/点赞对齐 → 歧义拒绝 → 出 ready/pending
   ▼
resolved_cards.json     每卡：object_id / nonce / key20302 / url / like_check / pos_check / status
   ▼
wx-viewer.py            ready 且有完整 URL 的卡片可点下载 → dl_engine.py 取流 + 内存明文头闸门校验
```

三个环节各自只持有一部分信息，**没有任何单一进程同时握有「标题 + oid + 完整 URL」**，必须跨三层按 oid 拼回：

| 层 | 进程 | 持有的信息 | 拿不到的信息 |
|---|---|---|---|
| UIA 界面树 | Weixin / WeChatAppEx | 封面、文案 desc、时长文本、点赞文本、网格位置 | 任何 ID（oid/nonce）、流 URL |
| 主进程配对 | Weixin.exe | oid ↔ 完整签名 URL（encfilekey/m/token/basedata/sign…）、出现次数、邻近 base64 元数据（部分残缺） | 文案、可靠的时长/点赞（邻近 blob 常解错或为空） |
| renderer 堆 | `--type=renderer` 的 WeChatAppEx.exe | oid、网格序号 index、解码 meta（vid_len/cur_like_count/feed_pos/scid）、邻近 20302 URL | 文案/昵称；完整签名常缺，键为早期缓存变体 |

---

## 2. 主键判定：为什么是 oid，而不是 encfilekey / m

### 2.1 可用作主键的标识

| 标识 | 形态 | 稳定性 | 说明 |
|---|---|---|---|
| **oid / object_id / feedId** | 16–20 位数字串，如 `15036571014753487580` | **稳定主键** | 前端卡片模型字段 `objectId`；renderer VNode 串里叫 `feedId`，ele_info 里叫 `feed_id`，主进程邻近对里在 URL 前逗号相邻。同一视频在不同层/不同时刻都是同一个 oid。 |
| objectNonceId / nonce | `时间戳_..._uuid` 形态 | 辅助，非主键 | 前端卡片模型字段 `objectNonceId`，随会话/上报变化；只在 renderer 旧路径里与 blob 同区，不能跨进程定位流。 |

### 2.2 不能当主键的键（实测零交集 / 随会话轮换）

| 键 | 位置 | 实测结论 |
|---|---|---|
| `encfilekey` | URL 参数 | 按流会话/码率轮换；主进程新取到的键与 renderer 堆内旧键 **0/17 同键**，不能跨进程当主键，仅在同进程内兜底归并。 |
| `m`（32 位十六进制） | URL 参数 | 同上，随会话轮换；主进程与 renderer 全文零交集。 |
| `token` | URL 参数 | 短时有效，过期即 400；不能重建、不能复用。 |
| 堆邻接位置 / 堆序 / URL 参数顺序 | 内存布局 | 三条离线归因均已证伪：不能靠「堆里谁挨着谁」或「URL 出现先后」推断归属。 |

> 实证依据：`main-pair.py` 提取主进程 `object_id ↔ encfilekey`；`mem-render.py` 按 oid/encfilekey/m 三键建索引；`card-resolve.py` 回表优先级为 **oid 直连 → encfilekey 兜底 → m 兜底**，ek/m 仅在 oid 缺失时使用。

### 2.3 oid 截断副本归并

正则偶发把 20 位 oid 截成 18–19 位后缀。`main-pair.py` 与 `card-resolve.py` 都做后缀归并：短 oid 若是某完整 oid 的 `endswith` 后缀，则并入完整 oid 并丢弃截断副本，避免同一视频被当成两个歧义候选。

---

## 3. 三层数据源细节

### 3.1 UIA 卡片（`tools/uia-collect.py` → `work/uia_cards.json`）

纯 comtypes UIA 枚举当前活动视频号主页网格，**UIA 树里没有任何 ID**，只有可见文案：

- 定位容器：先按顶层窗口归层，沿父链上溯到 `finder-profile-wrapper`（账号隔离层，不用 COM 代理对象 id 分组）；
- 选活动层：焦点祖先 → 视口中心点命中祖先 → 兜底取卡片最多的窗口；
- 卡片节点：类名 `click-box`，矩形过小（宽 <80 或高 <120）剔除；
- 后代 Text 归类：`时长` 正则 `^\d{1,2}:\d{2}(:\d{2})?$`；`点赞` 正则 `^\d+(\.\d+)?[万wW]?$`（「2.1万」×10000 换算）；其余最长文本作文案；
- 排序：按行（中心 y/60）再按列（中心 x），赋网格序号 `index`；
- 另抓取头部「N 条原创内容」总量 `total_count`。

输出卡片字段：`rect / cover / duration / seconds / like / like_int / desc / index`。

### 3.2 主进程权威配对（`tools/main-pair.py` → `work/main_pairs.json`）

扫描主进程 `Weixin.exe`（自动选配对数最多的主进程，可 `--pid` 指定）的已提交私有内存区域（MEM_PRIVATE、非 NOACCESS/GUARD、≤64MB），正则：

```
(\d{16,20})[,"\s]*(https://finder\.video\.qq\.com/251/(\d+)/stodownload?[^\s"'<>\\;,[\]()]+)
```

- 行为/取流上报记录里，**oid 与 20302 流 URL 逗号相邻、同一条记录内**；
- 从 URL query 解析 `encfilekey / m / token(前24位) / uzid`，记录出现次数 `n`；
- 在记录附近窗口（8000 字节）找 ≥80 字符 base64，解码为 recsys JSON，提取 `vid_len / like / comment / feed_pos / tab_feed_pos / page_num / scid / aid / request_id / tab_session_id`；
- 同一 oid 先出现短引用（缺 sign/basedata）后出现完整签名 URL 时，**参数更全的覆盖短的**，避免把会被 CDN 拒 400 的残缺 URL 落库；
- URL 边界在 `,;[]()` 处截断，防止把上报 JSON 尾部并入。

**注意**：主进程邻近 base64 元数据经常残缺或解错（实测样例 `vid_len=None`、`like=518032` 与卡片 515 不符），所以时长/点赞对齐不能只信主进程 meta。

### 3.3 renderer 堆结构化记录（`tools/mem-render.py` → `work/mem_model2.json`）

枚举所有命令行含 `--type=renderer` 的 `WeChatAppEx.exe`，堆内抽取三类形态，按 oid 合并：

| 类型 | 正则形态 | 产出字段 |
|---|---|---|
| ① VNode 卡片串 | `finder-profile-card,{"feedId":"<oid>";"cols":n;"index":i}` | 网格序号 `index` |
| ② ele_info | `"feed_id":"<oid>","session_buffer":"<base64>"` | 解码 meta：`vid_len / cur_like_count / feed_pos / scid / object_id` |
| ③ 邻近对 | `<oid>,https://.../20302/stodownload?...` | 流键与邻近 URL（media.20302） |
| ④ 旧路径兜底 | `nonceId` 后 base64 recsys blob + 邻近 20302/20304/20350 URL | nonce、解码 meta、按接口号分类的媒体 URL |

- URL 缺 scheme 前缀时补全 `https://finder.video.qq.com/251/20302/stodownload?`；
- 跨 renderer 进程按 oid（或 nonce）合并：空序号/空 meta/空 nonce 用新记录补齐，`media` 字典取并集。

### 3.4 接口号与媒体类型

URL 路径 `/251/<接口号>/stodownload`：

| 接口号 | 类型 | 用途 |
|---|---|---|
| 20302 | 原画视频流 | 下载目标 |
| 20304 | 封面 coverUrl | 核对画面，不下载 |
| 20350 | 缩略图 thumbUrl | 列表缩略图 |

---

## 4. 对齐算法（`tools/card-resolve.py`）

### 4.1 候选池构建

1. 载入三源 JSON；renderer 记录按 `oid / ek / m` 建三键索引；
2. 主进程配对只取 `kind == "20302"`；截断后缀副本并入完整 oid；
3. 每条配对优先用 renderer 记录补字段：`len / like / index / pos / page / scid / aid / nonce / url`；renderer 缺失才回退主进程 meta；
4. **renderer 独有**（主进程未出现）但自带邻近 URL 的记录也补进候选池；
5. 候选按时长 `len` 分桶（`by_len`）。

### 4.2 对每张 UIA 卡片打分选候选

- 先按时长精确相等取桶 `by_len[sec]`，排除已被占用的 oid；
- 打分键（先序号，后点赞）：

  - `idx_pen`：序号都有且相等 → 0；序号不符 → `100 + |index差|`；任一侧序号未知 → 50（中性偏后）；
  - `like_pen`：点赞都有 → `|like_mem - like_uia| / max(like_mem, 1)`；任一侧缺失 → 999；
- 排序：`(idx_pen, like_pen)` 升序，取榜首。

### 4.3 歧义拒绝（不猜）

榜首与第二候选同时满足：

- 点赞接近：两者 `like_pen ≤ 0.15`；
- 序号接近：两者都有序号且 `idx_pen` 差 ≤ 1；

则判定歧义，**不绑定**，`status=pending`，备注「多条同时长候选，序号/点赞无法区分」。

### 4.4 校验与状态

- 点赞校验：相对差 < 0.15 记 `like_check=Y`，否则 `N`（备注「点赞与卡片不符，可能错配」）；
- 序号校验：相等 `pos_check=Y`，差 1 记 `~`，否则 `N`；
- **ready 判定**：URL 同时含 `sign=` 与 `basedata=` 才算完整可取流；缺签名参数 → `pending`，备注「流地址不完整（缺签名参数），重新悬停取流」；
- 已占用 oid 不重复分配给下一张。

### 4.5 字段来源优先级（避免主进程脏 meta 污染）

- 时长/点赞：renderer 解码值优先，主进程 meta 仅在 renderer 缺该字段时兜底；
- 完整 URL：主进程配对优先；主进程 URL 残缺时回退 renderer 邻近 URL；
- 序号/位置/scid：renderer 优先，主进程 meta 兜底。

---

## 5. URL 参数与可达性

### 5.1 完整 20302 URL 参数

```
https://finder.video.qq.com/251/20302/stodownload?
  encfilekey=<流会话密钥>
  &hy=SH &idx=1
  &m=<32位hex>
  &uzid=<>
  &token=<短时签名令牌>
  &basedata=<base64 上报/鉴权块>
  &sign=<签名>
  &web=1 &extg=<>
  &svrbypass=<> &svrnonce=<> &taskid=<> &fexam=1 &X-snsvideoflag=<>
```

### 5.2 实测可达性规则

- 必须保留**原始完整 URL**（含 `basedata/sign/svrbypass/svrnonce/taskid/extg/web`）；只拼 `encfilekey/m/token`、或去掉 `sign/svrbypass` 重建，CDN 返回 **400**；
- `token/sign` 服务端签好，**外部不能重签**；缓存地址只能短期复用，过期需重新悬停取流；
- 可取流验证：发 `Range: bytes=0-0`，返回 **206 Partial Content**、`Content-Type: video/mp4`、`Content-Range: bytes 0-0/<整文件字节数>`；
- 整文件字节数是后续内存明文头闸门的硬比对基准（见 §7）。

---

## 6. 完整样例（已 viewer 链路落盘核对通过）

当前账号「杠京-北京杠爷」，resolved index 12：

| 环节 | 字段 | 值 |
|---|---|---|
| UIA 卡片 | 序号 index / 时长 / 点赞 / 文案 | 12 / 00:45 (45s) / 515 / 「我们在公园表演老北京天桥绝活宫廷盘杠，受到观众们热烈欢迎！#宫廷盘杠 #单杠 #高手在民间 #公园健身」 |
| renderer 记录 | oid / index / vid_len / cur_like_count / feed_pos / 邻近 20302 URL | `15036571014753487580` / 12 / 45 / 515 / 12 / 有 |
| 主进程配对 | oid / kind / 出现次数 n / m / token | `15036571014753487580` / 20302 / 138 / `20c3f542…` / `ic1n0xDG6a…` |
| 主进程邻近 meta | vid_len / like / scid | `None` / `518032`（脏值，被 renderer 的 515 覆盖）/ `0e1814b6-…` |
| 流可达性 | HEAD 206 | `bytes 0-0/5541982` |
| 落盘文件 | 路径 / 字节数 / 编码 / 时长 | `视频号_20261117_022428_576p_46s.mp4` / **5,541,982（与流总长精确相等）** / hevc 576×1024 + aac / 45.933s |
| 画面核对 | 抽 5s 帧 | 公园绿色单杠架、两人立于软垫、围观人群，与封面/文案一致 |

> 主进程 meta 的 `like=518032` 与卡片 515 不符，正是 §4.5 「renderer 值优先」要解决的情况；本例最终点赞以 renderer/UIA 的 515 为准。

### 统计口径（一轮实测快照）

15 卡：命中 10 / ready 10 / 点赞一致 9 / 序号一致 10 / 歧义 0。未命中条目对应当时未悬停/未播放、堆内尚无记录的卡片。

---

## 7. 下载前的二次闸门（内存明文头，不在配对层）

卡片 ↔ URL 绑定正确，不等于一定能下载：加密流要先在微信侧实际解码，明文 MP4 头才会进入 `WeChatAppEx` 内存。

- **激活方式**：在封面 hover 长停约 8 秒即可常驻明文头，不必点开播放窗口；未悬停/未播放的卡片早筛会被拦下；
- **头是有限缓存**：新头进入会把旧头挤出，下载必须在头仍驻留的窗口内完成；
- **闸门校验**（`tools/dl_engine.py`）：HEAD 整文件大小与任一常驻头声明长度比对，容差 `max(1024, 0.0002*total)`；再走 MP4 结构（ftyp/moov/mdat）、时长 ±3s、双段解码校验；
- **邻条预取干扰**：同屏邻条也可能被预取进头，不能只看「有新头」，必须大小 + 时长 + 解码三重对上；
- 诊断产物：`work/diag_heads.json`（pid / 地址 / first 盒 / moov_end / mdat / declared 声明长度）。

---

## 8. 已知边界与失败模式

| 现象 | 原因 | 现状处理 |
|---|---|---|
| 卡片状态一直「待取流」 | 未悬停/未播放，主进程/renderer 堆内尚无该 oid 记录或完整 URL | 重新在微信里悬停/播放几秒后刷新；ready 需 URL 含 sign+basedata |
| 点下载报「内存无明文头」 | 明文头已被挤出内存或从未解码 | 回微信悬停/重播该视频几秒后重试 |
| 「流地址失效或残缺」 | token/sign 过期，或 URL 缺签名参数（400） | 重新悬停取流，刷新拿到新 URL |
| 「内存头与地址不配对」 | 常驻头属于别的视频（大小/时长对不上） | 重播/重悬停后重试；引擎跳过不配对候选 |
| 歧义拒绝 | 多条同时长且序号/点赞都接近 | 不猜测，置 pending，等待更多信号（序号/点赞落位） |
| 主进程 meta 时长/点赞为空或解错 | 邻近 base64 记录边界残缺、blob 归属错位 | 用 renderer 解码值覆盖；缺 meta 的卡片对齐置信度下降 |
| 文案/昵称取不回 | 只存在于 UIA，内存记录与 URL 都不含 desc | 文案始终以 UIA 卡片为准，回表只挂 oid/URL/键 |
| 翻页/换号后旧记录残留 | 旧会话堆记录未被回收 | 靠序号 + 时长 + 点赞复合排除；换号由 slot 注册表重置 |

### 已验证为死路（勿重复尝试）

成品 MP4 box 树无标题/作者/封面轨；stodownload URL/basedata 不含标题；本地 DB 全 SQLCipher 加密、缓存无明文键；xplayer 瘦 slave 不留流标识；无远程调试端口；堆邻接/堆序/URL 参数三条离线归因证伪；cgi 经 WeixinJSBridge 原生桥代发，外部 Python 无法直接复放；不能靠内存调用原生桥生成 token。详见 `association-research.md` §4。

---

## 9. 脚本与产物清单

| 步骤 | 脚本 | 产物 |
|---|---|---|
| UIA 卡片枚举 | `tools/uia-collect.py` | `work/uia_cards.json` |
| 主进程 oid↔URL 配对 | `tools/main-pair.py` | `work/main_pairs.json` |
| renderer 堆模型聚合 | `tools/mem-render.py` | `work/mem_model2.json` |
| 绑定解析/对齐/出状态 | `tools/card-resolve.py` | `work/resolved_cards.json` |
| 编排刷新（依次跑上面三步再解析） | `tools/refresh.py` | `work/refresh.log` |
| 常驻明文头诊断 | `tools/diag-heads.py` | `work/diag_heads.json` |
| 下载解密引擎 | `tools/dl_engine.py` | 成品 MP4 → `%USERPROFILE%\Documents\视频号` |
| 界面 | `wx-viewer.py` | 读 resolved_cards + slots + library2 合并展示 |

复跑（Python 3.14，显式解释器路径）：

```powershell
$py = "C:\Users\ASUS\AppData\Local\Programs\Python\Python314\python.exe"
& $py tools\uia-collect.py
& $py tools\main-pair.py
& $py tools\mem-render.py
& $py tools\card-resolve.py
```

或一次性编排：`& $py tools\refresh.py`。

### 下载记录与槽位

- `work/library2.json`：以 oid 为键的下载终态（object_id/nonce/desc/duration/like/status/file/error/updated）；
- `work/slots.json`：按账号持久化的槽位注册表，刷新时把新快照对照回槽位更新状态，换号重置。
