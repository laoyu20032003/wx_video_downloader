# 非 hover 下载探索（non-hover）

> **DeepSeek Harness** · 文档整理与验证
>
> **来源**：豆包本地探索记录（2026-11-17，原文件 `D:\Doubao\wx_video_downloader\docs\non-hover.md`）。
> 豆包 package/探针不随本仓库提交。
>
> **当前状态：暂不继续 non-hover。**
> 应用层路线已逐项实测关闭；本仓库的 `wx-viewer` 仍走 hover 8 秒路径。
> 剩余唯一未证伪的硬路是 Q5（主进程 MM 协议帧密钥 + Python 复放 cgi），成本高、风险大，不作为近期目标。
>
> 本文保留完整证据，避免以后重复踩坑。

> **状态：2026-11-17 起暂停，以后有机会再续。** 应用层路线已逐项实证堵死；未证伪的硬路只剩 Q5（内存提取 MM 协议帧密钥并 Python 复放 cgi）。本地可控的 seed 留存/自解密兜底见任务 #20，不属于 non-hover 探索。
>
> 目标：摆脱现有路径对「桌面前台 + 手动/程序悬停触发取流」的依赖，在不占用用户桌面的前提下，离线或后台拿到每条视频可下载的材料。本文从**路径 2（复放原生 feed cgi / 离线获取列表媒体材料）**开始探索；路径 1（hover 触发、被动捕获完整 URL）已在 `wx-viewer.py` 落地，路径 3（本地拼 stodownload URL）已证不可行。
>
> 关联：`card-url-binding.md`（卡片↔URL 配对与参数缺口）、`association-research.md` §9.2 / §16.34 / §16.39 / §16.42。

---

## 1. 现状与问题

### 1.1 已落地的路径 1（hover 触发，被动捕获）

链路：UIA 枚举卡片 → 程序/手动在封面 hover 长停，微信内部解码并取流 → 主进程内存扫描捕获 `oid ↔ 完整签名 20302 URL` → `dl_engine.py` 凭内存明文头闸门校验后落盘。

**缺点（本轮要解决的）**：
- 占用用户桌面：微信视频号窗口必须在前台、不被遮挡，滚动/悬停由程序或人工完成；
- 依赖头驻留窗口：明文头是有限缓存，会被新头挤出，下载必须赶在淘汰前完成；
- 人工参与：未悬停/未播放的卡片在堆内尚无记录或完整 URL，界面只能标「待取流」；
- 自动刷新重扫内存约 46s，与下载引擎争 CPU。

### 1.2 non-hover 的两层目标（先分层，避免一步到位）

| 层级 | 目标 | 成功标准 |
|---|---|---|
| L1 列表材料离线获取 | 不 hover，拿到每条 `oid ↔ 媒体材料`：`media.url / urlToken / decodeKey / 规格 / 封面 / 时长 / 点赞 / 文案` | 离线重放或被动读到与当前 UIA 批次指纹（时长/点赞/文案）对上的 `object[]` |
| L2 免触发下载地址 | 不经过 hover/播放器在场，拿到可直接 206 下载的 20302 密封 URL | 仅凭 `oid`（+ L1 材料）经一次可复放请求得到 `Range: bytes=0-0` 206 |

> 注意：L1 打通不等于 L2 打通。列表材料和播放授权 URL 是两条信息流（见 §2），密封参数可能在另一次授权步骤才签发。

### 1.3 硬约束（不可逾越）

- 不本地伪造 `sign / svrbypass`：无密钥无算法，实测去掉即 400；
- 不靠内存调用 `WeixinJSBridge` / 原生桥；
- 扫描只读不造明文头；
- 历史/广告/预加载残留必须按当前批次排除，不能回表旧缓存。

---

## 2. 两条信息流（必须先分清）

### 2.1 A 列表信息流（feed cgi 响应）

作者主页 / 推荐列表响应里的卡片模型对象（前端 Feed 类，§9.1）：

| 字段 | 含义 |
|---|---|
| `id / objectNonceId / encrypted_objectid` | 稳定对象标识（oid / nonceId / 加密 id） |
| `objectDesc.description` | 标题/文案 |
| `contact.username / nickname` | 作者标识 / 昵称 |
| `media.url + media.urlToken` | 流地址基址 + 令牌；`videoUrl = https(url + urlToken)`，主机 `wxapp.tc.qq.com` → `finder.video.qq.com` |
| `media.decodeKey` | 解密密钥（加密视频标记） |
| `media.spec / hdrSpec / width / height / fullThumbUrl` | 清晰度规格、宽高、封面 |
| `media.videoPlayLen` | 时长（秒） |
| `likeCount / commentCount / ...` | 点赞/评论等 |

### 2.2 B 播放授权流（20302 stodownload URL）

hover/播放时换取的 CDN 下载地址，参数归类见 `card-url-binding.md` §5.3。其中本地造不出来的密封件：`encfilekey / m / uzid / token / basedata / sign / svrbypass`。

### 2.3 核心未知（路径 2 要回答的第一件事）

1. A 响应里的 `media.url / urlToken / decodeKey` 能否直接拼出可下载地址？
2. 还是必须再经过一次「授权 cgi」才签发 B 的密封参数？
3. 这次授权是否要求 xplayer / 播放器实例或 UI 状态在场？

---

## 3. 已掌握的实证事实

### 3.1 原生 cgi 表（§9.2 / §16.34）

| 动作 | cgi | cmdid |
|---|---|---|
| 作者主页列表 | `pc_finderuserpage` | 6624 |
| 作者主页预览 | `pc_finderuserpagepreview` | 20142 |
| 播放历史/播放列表 | `pc_findergetplaylist` | 9586 |
| 相关推荐 | `pc_findergetrelatedlist` | 5222 |
| 已互动列表 | `pc_findergetinteractionedfeedlist` | 24159 |
| 对象详情 | `pc_findergetcommentdetail` | 5259 |
| 关注/收藏/点赞列表 | `pc_findergetfollowlist / favlist / likedlist` | 9758 / 11046 / 6418 |
| （候选）播放流 | `pc_finderpcflow` | 11597 |

**主页接口请求体**（`finderUserPage`）：`{username, objectId, finderUsername, lastBuffer, needFansCount, sessionBuffer, finderBasereq}`；分页游标 `lastBuffer`，结束标志 `continueFlag===0`。

**响应体**：`object[]`（卡片模型）、`lastBuffer`、`continueFlag`、`originalInfo.originalCount`（原创总数）、`contact`、`fansCount`、`bizInfo`。

### 3.2 通道封堵现状（在线实测）

- **调用通道**：前端 `post → invoke → window.WeixinJSBridge.invoke("finderH5ExtTransfer", {url, data})`，由原生主进程接管转 MM 协议；不是普通 XHR / 公网 HTTP。
- **代理抓包**：`flows.log` 只见到 `finder.video.qq.com/251/20302/stodownload` 的 206 分段 GET，**没有任何 cgi 主机记录**；`capture.py` 对非媒体响应只记 URL/状态/大小、不落 body；当前 mitmdump 未运行；系统代理 `127.0.0.1:20808` 非本工具链路。
- **长链端点实测**：枚举全部 Weixin/WeChatAppEx TCP 连接，仅主进程 `Weixin.exe` 持有一条 Established 长链（IPv6 远端 `:80`，无反向 DNS）；AppEx/renderer 无外联，经本地 IPC 与主进程通信。cgi ride 在主进程这条长链上，不在可被 mitmproxy 直接拦截的 HTTP 连接池里（PID 为快照，重启后按角色重判）。
- **代理旁路实测**：微信进程对 `127.0.0.1:20808`（系统代理 xray）**零连接**；长链为直连，不经过 WinINET 系统代理。挂在系统代理上的 mitmproxy（HTTP 代理模式）看不到 MM cgi；要截获这条直连长链，只能走透明代理 / WFP 网络过滤驱动 / 进程内观测，成本与摩擦显著抬高。
- **无调试端口**：所有 WeChatAppEx 进程命令行不含 `--remote-debugging-port`；本机 9222 / 9223 / 9229 / 8315 / 8316 无监听；主进程本地 14013/16/19/22/23 端口 `/json/version` 均非 HTTP CDP。
- **数据库**：本地 xwechat_files 业务库全 SQLCipher 加密，未取到会话密钥；缓存无明文键。
- **xplayer**：瘦 slave，不留 URL/键/对象标识。

### 3.3 已验证死路（勿重复尝试）

- 成品 MP4 box 树无标题/作者/封面轨；stodownload URL / basedata 不含标题；
- 堆邻接位置、堆序、URL 参数顺序三条离线归因均证伪；
- 只拼 `encfilekey/m/token`、或去掉 `sign/svrbypass` 重建 → CDN 400；
- `token/encfilekey` 短时有效、随会话/码率轮换，过期不可复用；
- 不能靠内存调原生桥；`sign/svrbypass` 只有服务端签好的副本，不能重签；
- 前端 JS 的 `media.urlToken` 与 20302 URL 里的 `token` 不是同一物，不可互替。

---

## 4. 路径 2 分解与探索步骤

### 2A 找到能读到 feed 响应体的观测点（L1 前提）

按成本从低到高，候选观测点：

#### 2A.1 代理层增强（先确认 cgi 是否过代理）

1. 启动 mitmdump 加载 `capture.py`，导入并信任本机证书；
2. 浏览一个视频号主页，通读 `flows.log` 全部主机清单（不只 qq.com 媒体）：确认是否存在 `/cgi-bin/micromsg-bin/...` 或 finder 列表类 HTTPS 请求；
3. 若有：改造 `capture.py`，对非媒体、非 JS/CSS 资源把响应 body 落盘到 `work/feed_bodies/`，按「时间戳 + oid/nid/exportkey」命名（媒体响应仍 `stream=True`，不缓冲视频）；
4. 检查 body 是否内嵌 SSR 卡片 JSON（`title/desc/nickname/oid/nid/encfilekey`）。

> 判定：cgi 若走原生长链、不经系统代理，代理层只能拿到 CDN 媒体，需转 2A.2/2A.3。

**2A.1 实测结论**：微信进程对系统代理 `127.0.0.1:20808` 零连接，长链直连 `:80`；HTTP 代理模式 mitmproxy 观测不到 MM cgi。此路在「系统代理挂 mitm」形态下关闭；仅剩透明代理 / WFP 过滤驱动这类内核级截获，成本高、影响面大，暂不优先。

#### 2A.2 内存差分捕获响应对象

1. 记录空白基线内存快照 → 在微信里打开/切换一个视频号主页 → 复扫主进程与各 renderer；
2. 差集内定位同时含 `object_id` 与媒体字段（`urlToken / decodeKey / videoPlayLen / fullThumbUrl`）的段；
3. 现有 `tools/mem-*.py` 偏 ASCII 扫描，需补：UTF-16LE 中文段提取、protobuf 长度前缀解析；
4. 与 UIA 当前批次按时长+点赞+文案指纹对账，确认是当前模型而非旧会话残留。

> 依据：§16.42 第 3b 层——feed cgi 响应 protobuf 内 `object_id + media + meta` 同消息；主进程命中过 `objectNonceId` 可读记录。

**2A.2 实测记录（本轮，只读探针）**

探针：`tools/probe-v8-fields.py`（字段名邻近转储）、`tools/probe-v8-json.py`（序列化 JSON 带值形态）、`tools/probe-main-keywords.py`（主进程关键词统计/邻近）。快照：main `[12960,34636,51620,53716,57040]`，renderer `[22464,48512,49288,50148,53676,56528]`；结果存 `work/v8_renderer.json`、`work/v8_fields_22464.json`、`work/v8_json_22464.json`、`work/v8_json_50148.json`、`work/main_keywords.json`。

| 观测点 | 命中事实 | 判定 |
|---|---|---|
| renderer 属性名 | `urlToken`×5、`decodeKey`×6、`videoPlayLen`×10、`objectDesc`×100、`objectNonceId`×63、`likeCount`×40（pid 22464） | 名字在，但邻近转储全是 JS 源码/描述符（`this.contact`、`o.coverInfo.fullCoverUrl`、`V.value?.decodeKey`、`get media(){...}`），**没有内联的 token/decodeKey/时长值** |
| renderer 序列化副本 | `"urlToken":"…"` / `"decodeKey":"…"` / `"videoPlayLen":n` 命中 **0**；仅匹配到已密封的 20302 stodownload URL | renderer 堆里没有带值的 L1 JSON 活副本；值在 V8 压缩指针槽位后，平铺扫字符串取不到 |
| 主进程关键词 | 仅长链主进程 57040 有命中：`wxapp.tc.qq.com`×897、`finder.video.qq.com`×717、`objectNonceId`×21、`videoPlayLen`/`fullThumbUrl` 各 1；`urlToken/decodeKey` 为 0 | 邻近核验：`objectNonceId` 在 `<finderFeed>` XML 分享残留；`wxapp` 全是 20304/275 表情贴图 URL；`videoPlayLen/fullThumbUrl` 在 schema 字段名字典块（0x7ffd…）。**主进程也没保留带值的 feed 材料 blob**；现存视频材料只有 hover 时捕获的密封 20302 URL |

**阶段性结论**：平铺 ASCII/UTF16 字符串扫描在 renderer 与主进程都拿不到 L1 材料值。两条剩余读内存路径：① 沿 V8 压缩指针走对象图（高成本，需解析 V8 堆布局/压缩指针）；② 在响应**被解析进 V8 之前**截获（代理层 2A.1，或 2A.3 调试端口直接读活模型）。

#### 2A.3 CEF 调试端口注入

- 包装重启 RadiumWMPF / AppEx，带 `--remote-debugging-port=<端口>`；
- 风险：release CEF 可能禁用 DevTools；且必须在正确的 finder 页面上下文里读取；
- 成功后可直接从 renderer 模型对象读完整 feed 数组，是 L1 最直接的观测点。

**2A.3 实测结论（本轮，已做包装启动器验证）**：

- **开关与代码**：`flue.dll` 含标准 Chromium 开关 `remote-debugging-port` / `remote-debugging-pipe`，并有 `CdpCommandEvaluateJavaScript` 路径（注释提示 evaluate JS 可能被 inspector 设置禁用）；inspector 代码未被裁剪。
- **无配置/环境开关**：`radium\web\Local State` 与各 profile `Preferences` 无 debug/devtools/inspect 键；MMKV 配置加密，无明文开关；`flue.dll` 内未发现 FLUE/WMPF/XWEB 调试环境变量（`NODE_DEBUG` 是内嵌 Node 的，与 CEF 无关）。
- **exe 包装路线被自愈拦截（实证）**：
  - 旁路：主进程带固定 `--helper-handle-value` / `--mojo-platform-channel-handle` 拉起 AppEx；stub 从 `--flue-runtime-dir` 加载 `flue.dll` 并交 `FlueMain`。
  - 准备了 x64 包装启动器（`tools/cef-debug-wrapper/`：`Proxy.cs` + `build.ps1`/`install.ps1`/`uninstall.ps1`），转发原命令行并追加 `--remote-debugging-port=9229`、继承句柄、回传退出码；临时目录冒烟测试转发与退出码回传通过（exit 7 正确回传）。
  - 安装后启动微信：插件目录清单 `26073\extracted\file_component.xml` 为**带签名的逐文件 MD5 校验**（`runtime\WeChatAppEx.exe` md5 `f20147eb7743849704e322c06ce4b8db`），并配 `ComponentVerification.dll`；启动时自检发现 exe 被替换，**自动从包体还原原始签名 exe**，包装被覆盖，9229 未监听。核验：还原后 exe MD5 与清单一致，目录已清理回原状，微信功能正常。
- **剩余注入方式（高摩擦、账号风险，暂不优先）**：① 运行时 DLL 注入主进程/AppEx，detour `CreateProcess` 命令行追加调试 flag（不落地改 exe，规避清单校验）；② 绕过清单/验签本身。两者都属代码注入/反篡改范畴，与本项目免费、本地、低侵入的取向冲突。
- 结论：**2A.3 的文件层注入已被堵死**；除非接受运行时注入，否则调试端口路线不可行。

#### 2A.4 SQLCipher 缓存库 / CEF 本地存储观测

- 定位 finder 相关缓存 DB，从内存提取 SQLCipher 密钥；
- 解出已缓存的 feed 对象（含媒体材料）；
- 风险：表结构未知、密钥提取与加密段解析成本高。

**2A.4 实测记录（本轮，只读探针）**：`tools/probe-db.py`、`probe-keyinfo.py`、`probe-leveldb.py`、`probe-xworker.py`、`probe-xworker-keys.py`、`probe-xworker-full.py`、`probe-xworker-all.py`、`probe-blob-seed.py`、`probe-title-disk.py`、`probe-db-raw.py`；结果 `work/leveldb_hits.json`、`work/videocache_records.json`、`work/xworker_records.json`、`work/title_disk_hits.json`。

**(a) 业务库盘点（活跃账号 9126，旧账号 dc1e 对照）**

- `db_storage` 下 20 个 `.db` 分 `message/contact/favorite/bizchat/chatbot/emoticon/general/hardlink/head_image/session/sns/third_app_icon`，**没有以 finder/feed/channel 命名的独立库**。
- 除 `all_users\login\<wxid>\key_info.db` 外，所有业务库文件头均为随机密文（无明文 `SQLite format 3` 头）；原始字节里对已知 10 个 finder oid 与一条标题片段**零命中**（空闲页也无残留明文）。候选存 feed 的 `general.db / session.db / sns.db` 均加密，表结构与内容未解。
- `key_info.db` 明文库，表 `LoginKeyInfoTable(user_name_md5, key_md5, key_info_md5, key_info_data)`：旧账号 1 行、活跃账号 **124 行**；`key_md5` 字段为空；每行 `key_info_data` 为 **180 字节 blob**，公共前缀 `0aa801000bb51739050000010000000000`、公共尾段 `200000006eb001aa1e57b69370d0718d0f`，中段每行不同（疑似按库/会话包裹的密钥记录，结构未反解；`pysqlcipher3` 未安装，内置 `sqlite3` 无法读加密库）。

**(b) CEF 本地存储全量扫描（`radium\web\profiles`，含 leveldb / IndexedDB / Session / Local Storage / CacheStorage / History / Share Data / Shared Dictionary）**

- 字段名 `urlToken / decodeKey / objectNonceId / videoPlayLen / fullThumbUrl` 与域名 `finder.video.qq.com`、路径 `stodownload` 在所有存储文件中 **0 明文命中**；18–20 位数字正则命中的多为飞书/百度/京东/金山文档/YouTube 等第三方站点噪声。
- 唯一与 finder 相关的持久化记录在 `IndexedDB\weixin_xworker_0.indexeddb.leveldb`：活跃账号 **24 个唯一 feedId**（218 条记录，多 seed/重试副本）。缓存键内嵌部分密封件，值 JSON 只有 6 个字段：

| 位置 | 字段 | 说明 |
|---|---|---|
| 缓存键 `finder:videoCache:<query>` | `encfilekey / m / uzid / hy / idx / X-snsvideoflag`（部分行含 `bizid / dotrans`） | 已密封件的**部分**；216 行带 `encfilekey`，150 行带非空 `m`，216 行带 `uzid/hy/X-snsvideoflag` |
| 值 JSON | `createTime / feedId / videoKey / preDownloadedContentLen / videoContentLen / seed` | 无标题/文案/作者/昵称/点赞/封面/时长，无 `urlToken/decodeKey`，无完整 20302 URL |

- **缺失的密封件**：缓存记录里没有 `token / basedata / sign / svrbypass`（这四项仍是服务端签发、本地不可造）；即本地缓存不足以重建可下载 URL。
- 本地分片：`radium\users\<hash>\xworker\liteapp\local\assets\tmp\wxalite…\finder\finder_videoCache_<16hex>`，当前磁盘仅 **2 个**（24 条记录中其余已被淘汰）；分片大小与 `preDownloadedContentLen` 精确相等，是加密前缀；文件头为随机密文。用记录里的 `seed` 做 32 位 LE/BE 及十进制串重复异或，首字节均还原不出 `ftyp`，前缀不是简单 seed-XOR。
- 反查结论：已采集卡片的 10 个 oid 与 15 条标题片段在整个 `radium` 与 `xwechat_files` 明文文件中**零命中**——卡片元数据（标题/作者/点赞/封面）不落本地磁盘，只活在运行时内存/当前响应里。

**2A.4 阶段性结论**：本地持久层对 L1 的贡献仅限「`feedId ↔ 部分密封件(encfilekey/m/uzid/…) ↔ 已淘汰的加密前缀分片 ↔ seed`」一张小缓存表；**列表卡片元数据不落地**，**完整密封下载地址不落地**。要读 `general/session/sns.db` 里是否另有 feed 表，必须先反解 180 字节包裹 blob、提取 SQLCipher 密钥（高成本，且即便解库，现有证据也不支持其中保存主页 feed 模型）。

#### 2A.5 前端调用链静态拆解：hover 到底触发了什么（可否跳过 hover）

探针：`tools/probe-js-keywords.py`、`probe-profile-js.py`、`probe-card-chunk.py`、`probe-670-js.py`、`probe-store-js.py`、`probe-store-block.py`、`probe-video-chain.py`、`probe-actions.py`、`probe-trigger.py`、`probe-preload-video.py`、`probe-preload-ctx.py`、`probe-jj.py`；目标包 `liteapp\local\packages\wxalite28e098851253e34f4777f7ca024236fd`（与缓存分片同包），主页 `pages/lite/profile.js`，卡片/播放器 chunk `670.js`，store `store-common.js`，公共库 `chunks-common.js`；`preloadVideo` 位于问问/问答包 `wxalite2fd372f050eecd471a4392786dfae78c`（非视频号包）。

**(a) 调用链逐层还原（静态读码）**

1. **卡片模型**：主页 `profile.js` 渲染卡片 VNode，仅透传 `feedId=feed.id / sessionBuffer / reqIndex / cols / index`；卡片组件 `FinderFeedCard` 接收 `feed / autoPlay`。
2. **事件层**：播放器子组件 emits `preview-start / preview-end`，冒泡到卡片；`onPreviewStart/onPreviewEnd` 回调里先埋点 `startPreviewCard / stopPreviewCard`（`feedId/sessionBuffer/reqIndex/stayTime`，纯上报）。卡片上挂的是 hover 指令 `{enter, move, leave}` 切换悬停态；另有 `IntersectionObserver` 负责曝光埋点，不负责取流。
3. **预下载函数**（`store-common.js` 模块 22336 `getVideoInfo(feed, flag)`）：
   - 取 `media.url` 与 `media.url+urlToken` 拼成 `videoUrl`；按 `spec/hdrSpec` 选码率规格；缓存键按 URL 参数排序生成 `finder:videoCache:<query>`。
   - 未命中缓存时：`fetch(videoUrl+"&web=1&X-snsvideoflag="+flag, HEAD)` 取 `Content-Length`，再 `fetch(Range: bytes=0..l-1)` 下载前缀（512KB–30MB，按总长/码率估算）；经 `lite.file` 文件系统写本地 `finder_videoCache_<sha256(videoUrl 末段)前16>`。
   - 落库记录即 2A.4 看到的 xworker `videoCache` 表：`{createTime, feedId, videoKey, preDownloadedContentLen, videoContentLen, seed=decodeKey}`。
   - `getPreDownloadedVideoBuffer` 再从缓存文件读出前缀 buffer，连同 `preDownloadedSeed(=decodeKey)/videoContentLen` 传给播放器 SDK 的 `preloadConfig`；解密由 renderer 内 `decrypt-video-core` worker + wasm 完成。
4. **两条原生通道**（与媒体前缀下载分开）：
   - **feed cgi**：`H5ExtTransfer`（`finderH5ExtTransfer`/`extTransfer`/`webTransfer` 包装），`lite.jsapi.invoke("H5ExtTransfer", {url, cgi_cmdid, scope, req_json, is_security_check})`，由原生主进程转 MM 协议；
   - **文件/宿主能力**：`lite.file`、`sendEventToHost`、`CallNativeTabApi` 等 jsapi。

**(b) 原生桥命令穷举（全包字面量去重）**

- `dispatchFinderAction(action, payload)` 仅 5 个 action：`AddFavorite`、`GetPreloadDataInterval`、`PrerenderWebview`、`WebviewReady`、`getFriendRemarks`。
- 全部 jsapi/bridge invoke 名 160+ 个；与视频相关的仅有：
  - **`preloadVideo({url, ratio})`**：位于**问问/问答 liteapp 包**（`2fd3…`，页面 `question/answer-collection/explore-search/image-answer/…`，非视频号推荐流）的 `useVideoPreload` 内，`preloadVideo(url) → jj=ve → lite.jsapi.invoke("preloadVideo",{url,ratio}) → 原生 Window.wg.native.invoke`；命中后写 redux 预加载表（`unifiedUrl/url`，TTL 10h）。**入参是已有的视频 URL，不含 feedId/oid**；它是给原生播放器实例的「按 URL 预取」提示，不是按标识换取授权流地址的命令。调用点是问答列表的防抖批量预载 `Promise.all(items.map(({videoUrl})=>preloadVideo(videoUrl)))`；该包播放器组件 `6861.js` 仅在切换 `videoUrl` 时用 `getMayBePreloadVideoUrl(url)` 读预载缓存，自身不主动预载下一条。
  - **视频号播放窗口（连续播放 flow drawer，包 `28e…`）未调用此 jsapi**；其前缀预载走 store 内部 fetch 路径（见 a-3），下一条缓冲由原生 xplayer/播放器实例内部管理，前端 minified 代码里看不到按 oid 触发下一条预载的桥命令。
  - **`previewVideo`**：相册/媒体选择器预览（`previewImage` 姊妹接口），与视频号卡片取流无关。
  - 其余 `chooseVideo/downloadGameVideo/delMiniGameVideo` 等均为小游戏/聊天文件场景。
- **没有任何 `Play / StartStream / ResolveFeedUrl / GetVideoUrl` 类按 feedId/oid 触发取流或换取地址的命令**；卡片包 `28e…` 的预下载走 store 内 fetch 路径（见 a-3），并不调 `preloadVideo` jsapi。

**(c) 对「能否跳过 hover 直接引发那次调用」的判定**

- **不存在一个可单独复放的「hover 系统调用」**。hover 在前端只是一个 enter/悬停事件；事件回调里做两件事：埋点上报 + 调内部 `getVideoInfo(feed)` 预下载前缀。原生侧没有对应「hover」命令。
- **无法从外部伪造原生命令触发取流**：桥命令清单里没有按 feedId/oid 取流或换取地址的 action；唯一相关的 `preloadVideo` 是按已有 URL 预取的提示，既不含标识、也不签发地址；预下载是前端组件闭包内的内部函数，不经桥 action 暴露。
- **理论上仅剩的程序化触发入口**：在 renderer V8 上下文里直接调内部 `getVideoInfo(feed)` / 卡片预览回调——这需要 JS 执行入口（CDP 调试端口或运行时代码注入），2A.3 文件层包装已被签名清单自愈堵死，仅剩高摩擦的运行时 DLL 注入。
- **跳过鼠标动作省不掉前置依赖**：即便能直接调 `getVideoInfo`，入参仍是 A 响应的 `media.url/urlToken/decodeKey/spec`；这些 L1 材料不落盘（2A.4）、平铺内存取不到（2A.2）。完整密封 20302 地址的 `token/basedata/sign/svrbypass` 仍需服务端在场签发。
- **唯一不依赖微信触发的环节**：前缀/流数据本身是对视频 URL 发 HTTP Range GET；若未来拿到一份有效的 `media.url+urlToken`（或已密封 20302 URL），Python 可直接 Range 取流，不必经过微信 hover——瓶颈始终是「材料/密封件从哪来」，而不是 hover 这个鼠标动作。

**2A.5 阶段性结论**：hover 是前端事件触发的内部预下载流程，不是一条可被外部独立调用的原生系统调用；原生桥未暴露按 feedId 取流的命令。跳过 hover 只能通过「在 renderer 内执行 JS」这一高成本入口实现，且不解决 L1 材料与 L2 密封件缺口。

#### 2A.6 卡片右键菜单「播放」能否程序触发（静态 + 运行时实证，2026-11-17）

探针：`tools/probe-context-menu.py`（运行时右键/菜单枚举/点击）、`tools/probe-uia-tree.py`（子树概况）、`tools/probe-windows.py`（进程/窗口诊断）；静态出处 `chunks-common.js` 模块 54271、`531.js` `GlobalContextMenu`。

- **菜单是 renderer 内 Vue DOM 弹窗，不是原生 Win32 菜单**：右键事件判定 `e.button===2`，经 contextMenu store（模块 89429）`showContextMenu({top:e.y,left:e.x}, lists)` 渲染；弹窗组件 `531.js` `GlobalContextMenu`（class `context-list / context-item / context-item__label`），定位到 `contextClickPosition`；每项是普通 `<div onClick>`：先 `e.cb()` 再 `hideContextMenu()`，菜单文本 `e.title` 落在 label div。菜单项**没有 `role="menuitem"`**，是普通 div。
- **「播放」项绑定的是父组件播放回调，闭包在当前 feed 对象上**。多个变体（推荐流/历史记录/反馈列表）的构造一致：
  - `{title:"播放", cb:()=>r(t,n)}`
  - `{title:"静音播放", cb:()=>r(t,n,{openMuted:!0})}`
  - 其余由 `v(t.id)` 追加：独立窗口显示、清除该记录、不感兴趣、复制/搜索选中等；`t` 为卡片 feed，`r/n` 为传入卡片的播放回调。
- **该回调与左键点开是同一条 goToDetail/打开沉浸抽屉链路**，不是单独的取流系统调用；菜单项不签发 URL，触发后仍走正常打开 feed 的材料加载/预下载流程。

**程序化触发两条路线判定**：

1. **UI 自动化（已运行时验证通过）**：comtypes UIA 从根枚举卡片（容器 class `click-box`、封面 `prev-i`），`win32api.mouse_event` 在卡片中心右键，约 0.8s 后 DOM 弹窗挂载；按文本「播放」取 BoundingRectangle 中心左键点击，成功打开沉浸抽屉。实测要点：
   - **菜单挂在 AppEx 子树，不在主进程窗口下**：主客户端 `Weixin.exe` pid 41832（Qt 框架窗 `Qt51514QWindowIcon「微信」`），菜单/卡片 DOM 实际在 `WeChatAppEx.exe` pid 47640 子树；必须从 UIA **根全树扫描** class `context-menu`，只在 41832 窗口子树内找会漏掉。
   - **菜单两种变体（作者页实测前 6 张）**：推荐/历史类卡片 → `重新进入视频号 / 投诉`（无播放项）；原创作品卡片 → `重新进入视频号 / 播放 / 静音播放`。不是每张卡片都有「播放」。
   - **菜单项是 Text 控件（UIA type 50020），无 `role="menuitem"`、无 InvokePattern**：只能按精确文本命中 + 矩形中心坐标点击，不能 `Invoke()`。
   - **触发后实证**：点「播放」后出现跨视口 `video-player` 层，目标卡片文案上移到抽屉头部、评论 op-item 出现；与左键点开同为 goToDetail 沉浸抽屉链路。
   - 收尾：`Esc` 关闭菜单；右键重复触发前需先关掉上一个菜单。
2. **直接调用内部回调（不可行）**：与 2A.5 同一堵墙——无 CDP 入口，桥命令清单里没有按 feedId/oid 播放或取流的 action；回调是卡片组件闭包，外部 Python 够不到。

**与 hover 路线的差别**：菜单「播放」是对**闭包里这一张 feed** 显式打开抽屉，不存在「划过多张卡同时预取」的归属歧义；但它仍是逐卡桌面动作，触发后受单播互斥约束（开一条、其余暂停），且不会额外给出密封 20302 地址。它的潜在价值是把「hover 等待取流」换成「显式点开这条」，归属由菜单项闭包保证；代价是逐卡打开窗口、占桌面。本次实测用的是全局鼠标消息，会抢前台/移动光标；`PostMessage` 直投子窗口能否在后台失焦状态触发、后台是否真正解码，尚未验证，分层判定见 `player-flow-architecture.md` §8.5。

**运行时环境备注（2026-11-17 19:10）**：已登录主客户端 pid 41832，派生 xplayer/wxpublic/wxocr 及多个 WeChatAppEx renderer/utility/gpu；MM 业务界面渲染在 AppEx 子进程。本机屏幕截图对 MM 表面存在不绘制现象（桌面/其他窗口可见，MM 画面抓不到），但 **UIA 树可达**，卡片、文案、时长、点赞、右键菜单均可枚举，自动化不依赖截图可见性。早期「窗口被压住/另一虚拟桌面导致无法实测」的阻塞已解除。

**2A 闸门**：在任一观测点读到与 UIA 当前批次对上的 `object[]`，每条带 `oid + 媒体材料`；否则 L1 未打通。

### 2B 列表材料 → 可下载地址的缺口（L2 前提）

探针：`tools/probe-2b-keywords.py`（全包关键词分布）、`probe-2b-cgimap.py`、`probe-2b-stream.py`、`probe-2b-media.py`、`probe-2b-registry.py`（注册表导出 `work/2b_cgi_map.json`，去重后 267 条）；样本：`work/videocache_records.json`（216 条 A 材料缓存键）、`work/resolved_cards.json`（10 条 ready B URL 参数普查）。

#### 2B.1 字段映射：A 列表材料 ↔ B 密封 20302 URL

**A 响应 media 模型（前端可见，`chunks-common.js` media getter 原样透传）**：

| A 字段 | 含义 | 是否进入 B URL |
|---|---|---|
| `media.url` | 流基址，query 已带 `encfilekey/m/uzid/hy/idx/X-snsvideoflag` | 基址与这些参数被 B 继承 |
| `urlToken` | 拼到 `url` 尾部的令牌（`url+urlToken`） | **≠ B 的 `token`**，不可互替；B `token` 是另一物 |
| `decodeKey` | 前缀/流解密 seed（缓存记录里的 `seed`） | 不进 URL；供 renderer wasm/worker 解密 |
| `spec` / `hdrSpec` | 码率/规格清单 | 选定规格后体现在 `extg` 等端位 |
| `width/height/videoPlayLen` | 尺寸/时长 | 不进 URL，供展示与对齐 |
| `fullThumbUrl/thumbUrl/coverUrl/fullCoverUrl` | 封面/缩略图（20304/20350） | 非下载目标 |

前端 `videoUrl` 拼接规则（静态读码）：`` `${url}${urlToken}` ``，主机归一 `wxapp.tc.qq.com → finder.video.qq.com`；路径含 `/20302/` 时补静态位 `&web=1`、`&taskid=pc-<playInsId>`、`&fexam=1`。

**B ready URL 参数普查（10 条主进程捕获的完整流）**：

| B 参数 | 出现率 | 归属 | 本地可否由 A 推出 |
|---|---|---|---|
| `encfilekey` / `hy` / `idx` / `m` / `uzid` / `X-snsvideoflag` | 10/10（`m`、`uzid` 9/10） | **A 材料 URL 已带**（与 videoCache 缓存键一致） | 否（随会话/码率轮换，但随 A 响应到手） |
| `token`（247 字符） | 10/10 | 服务端签发令牌 | **否**，≠ urlToken，过期 400 |
| `basedata`（219 b64） | 10/10 | 服务端组装鉴权/上报块（protobuf 形态） | **否**，本地无组包密钥与上下文 |
| `sign`（86 字符） | 10/10 | 服务端签名（密钥+内容哈希） | **否**，实测去掉即 400 |
| `svrbypass`（120 b64） | 10/10 | 服务端防重放票据 | **否**，实测去掉即 400 |
| `svrnonce` | 10/10 | 与 `sign/svrbypass` 绑定的 nonce/时间戳 | 可造但绑定签名，单独造无效 |
| `web` / `fexam` / `taskid` | 10/10 | 前端补的静态端位（见 videoUrl 拼接器） | 静态可填，但受签名绑定 |
| `extg` | 10/10 | 规格/端扩展位 | 半静态，按清晰度规格取值 |
| `bizid` / `upid` / `dotrans` | 1/10 | 条件下发 | 否 |

**映射结论**：A 能给到的是「基址 + encfilekey/m/uzid/hy/idx/X-snsvideoflag + urlToken + decodeKey + 规格」；真正卡脖子的密封件是 **`token / basedata / sign / svrbypass`**（`svrnonce` 配对），前端代码与本地持久层都拿不到。

#### 2B.2 接口普查：有没有按 oid 换播放地址的授权 cgi

注册表全量解析（`work/2b_cgi_map.json`）。视频号主页/推荐相关接口：

| 前端方法 | cgi | PC cmdid | scope | 安全位 | 响应形态 |
|---|---|---|---|---|---|
| FinderUserPage | `pc_finderuserpage` | 6624 | — | — | `data.object[]` 列表模型 |
| FinderUserPagePreview | `pc_finderuserpagepreview` | 20142 | finderProfile | — | 列表预览 |
| FinderPcFlow | `pc_finderpcflow` | 11597 | finderProfile | ONCE | `data.object[]` 流列表 |
| FinderStream | `pc_finderstream` | 8060 | finderProfile | ONCE | `data.object[]` 流列表（**非单条换地址**） |
| FinderGetRecommend | `pc_findergetpcrecommend` | 6638 | — | ONCE | 推荐 `object[]` |
| FinderGetRelatedList | `pc_findergetrelatedlist` | 5222 | — | — | 相关推荐 `object[]` |
| FinderGetPlayHistory | `pc_findergetplaylist` | 9586 | finderProfile | — | 播放历史 `object[]` |
| FinderGetInteractionedFeedList | `pc_findergetinteractionedfeedlist` | 24159 | finderProfile | — | 已互动 `object[]` |
| FinderGetFollowList / FavList / LikedList | `pc_findergetfollowlist/favlist/likedlist` | 9758 / 11046 / 6418 | finderProfile | — | 列表 `object[]` |
| FinderBatchGetObjectAsyncLoadInfo | `pc_finderbatchgetobjectasyncloadinfo` | 8050 | — | — | 按 `objectUidList` 取附加信息（直播连麦等） |
| FinderCheckPrefetch | `pc_findercheckprefetch` | 11077 | — | — | 红点/预取校验 |

- **所有列表类 cgi 响应都是 `data.object[]` feed 模型**，携带 A 材料；`FinderStream(8060)` 名字像「取流」，静态读码确认它仍返回 `object[]`（`finderStream(e)` 与 `finderPcFlow` 同构，只是入参/场景不同），**不是按 objectId/nonceId 换取密封播放地址的接口**。
- JS 里出现的 `streamUrl / playUrl / replayUrl` 全部属于**直播**（`liveInfo.streamUrl`、FLV 直播播放器）或**直播回放**（`renderReplayUrl`），与点播视频号卡片的 20302 stodownload 无关。
- 全包代码扫描：`stodownload / encfilekey / svrbypass / basedata / uzid` 作为**代码字面量 0 命中**（`encfilekey` 只作为模型里的字符串值出现，不在前端拼接/签发逻辑里）；前端没有任何把 oid 变成密封 20302 URL 的函数或 cgi 调用。

#### 2B.3 依赖判定（静态）

- 密封 20302 URL 不在 webview 侧生成：前端只持有 A 材料并对 A videoUrl 做预下载前缀；密封地址出现在主进程/原生侧内存（2A.4、配对链路实测）。
- 静态层面无法判定密封 URL 的产生方式是以下哪种，需原始响应/协议抓包区分：
  1. 原生播放器用 A `videoUrl` 发起请求，CDN/MM 层 **302 跳转**到已签发的 stodownload 地址；
  2. 存在一个 **native-only 授权 cgi**（不暴露给 liteapp 前端），按 objectId/材料换取 `token/basedata/sign/svrbypass`；
  3. 两者混合（A 基址先换短期令牌，播放器再带令牌换密封票据）。
- 触发条件（结合 2A.5）：预下载/起播由播放器组件在 preview-start/悬停态内部发起；原生桥无独立「按 feedId 取流」命令。授权是否必须 xplayer/播放器实例在场，静态代码不能完全证伪，倾向需要起播阶段触发。

#### 2B.4 直连验证现状（未打通）

- 离线换取地址需要：一份原始 A 响应体（核对 `url/urlToken/decodeKey/spec` 与 B 参数的实际映射，任务 #4）+ 2C 的 MM 协议帧封装/鉴权复放。
- 在此之前无法对「仅凭 oid + A 材料离线拿 206 可下载 URL」做实证；静态证据不支持纯本地拼密封 URL（见 §5.3 与 2B.1 映射表）。

#### 2B.5 官方公开文档对照（developers.weixin.qq.com/doc/channels）

通读公开「视频号」开发文档目录与代表性接口（2025–2026 版本）：

- **公开面是「视频号助手 / 小店」商家服务端 API**，主机 `api.weixin.qq.com/channels/ec/...`，鉴权为 `appid + secret → access_token`（7200s，`/cgi-bin/token`），带 IP 白名单、权限集 id、第三方 `authorizer_access_token` 代调，**强制服务端调用、禁止前端直调**。
- 接口分类：基础凭据、罗盘达人版（概览/商品/销售画像数据）、线索（leads）、直播记录/直播数据、橱窗商品、本地生活核销/订单/券。**没有任何「获取用户主页作品列表 / 点播视频源地址」接口**。
- 已核对的代表性返回体：
  - 罗盘商品列表：仅 `product_id/head_img_url/title/price/类目 + GMV/订单/佣金统计`；
  - 直播记录：仅 `export_id/description/cover_url/nickname/head_url`，**无回放/点播流地址**；
  - 橱窗商品列表：`product_id/appid/out_product_id/product_source + last_buffer/total_num`；
  - 概览：纯金额统计。
- 分页设计印证私有 feed 结构：公开橱窗列表用 `last_buffer` 顺序游标 + `total_num`，与私有 `pc_finderuserpage` 的 `lastBuffer/continueFlag/originalCount` 同构；但公开面不下发任何 20302 stodownload 密封地址。

**对照结论**：

1. 公开 API 与消费端 MM 私有协议是两套鉴权/主机/权限体系；公开 `access_token` **不能**替代 MM 会话凭证去复放 `pc_finder*` 长链 cgi，也换不到密封流 URL。
2. 官方即便给创作者/商家的接口也只给封面/商品/统计，不下发原始视频源——与我们实测「流地址按播放器会话密封、前端不可见」一致，说明源地址不通过公开业务接口下发是产品设计，不是我们没找到接口。
3. 可借鉴的只有分页游标命名/形态（`last_buffer`/`total_num`），对 2C 复放私有 cgi 的请求/响应解析有参考价值，无鉴权捷径。
4. 旁证：本地 `D:\github_wechat` 下两个公开仓库（Go `uuappli/wechat-token`、PHP `threeidiot/wechat-token`）均为公众号/小程序 **access_token + jsapi_ticket 中控服务器**（`/cgi-bin/token`、`/cgi-bin/ticket/getticket`，DB 缓存定时刷新），与本项目无关；其「token」是开放平台 appid/secret 离线兑换的服务端凭据，**不是**点播流密封 URL 里的 `token/basedata/sign/svrbypass`，代码中零 finder/feed/20302/objectId 命中。

#### 2B.6 本地开源参考实现对照（`D:\github_download`）

两份只读参考克隆，2026-11-17 已 `fetch`：`ltaoo/wx_channels_download` main 至 `1d3b4678`（2026-11-10，本次快进 1 个提交，改动仅日志级别/前端 handler，未动取流与解密）；`putyy/res-downloader` master 停在 `f8ac4d9`（2026-08-12，另有 `release/v4.0` 分支与 `4.0.0-beta.8` tag）。

**res-downloader（Go + Wails，通用资源嗅探）**：

- 本地 goproxy 透明代理 + 自签 CA；对 H5 视频号（`channels.weixin.qq.com` / `res.wx.qq.com`）改写 bundle：hook `get media()` getter 与 `finderGetCommentDetail`，把 `objectDesc` POST 到本地 `/res-downloader/wechat?type=1/2`；后端解析 `media[0].url+urlToken`、`decodeKey`、`coverUrl`、`description`、`spec.fileFormat`，按 `md5(rawUrl)` 去重后推资源列表。
- 视频分片按 `finder.video.qq.com` + `Content-Type: video/mp4|octet-stream` 识别；**oid↔URL 绑定完全依赖被改写的 H5 feed 对象本身**（objectDesc 内 url/urlToken/decodeKey/desc 同体），服务端不做配对。
- 适用前提是 4.0/4.1 的 **H5 网页视频号**；4.2 liteapp 原生化后页面不经过可注入的 webview，这条注入链路失效（与其自带 `_capture/wxtest2/docs/how-it-works.md` 第 1 节判断一致）。

**wx_channels_download（Go，fork 演进版）**：

- 双链路：① 透明代理记录 `finder.video.qq.com` stodownload 分片（不改写响应，`stream=True` 透传避免缓冲）；② 读 `WeChatAppEx.exe` 内存，按 MP4 box 结构（`ftyp`…`moov`，允许夹 free/uuid，最多跨 3 个）定位解密后明文头，dump 131072 字节。
- 媒体身份判定：起播那条地址带 `m=<32hex>`；其余预加载/封面 `m=` 为空，退到 `encfilekey` 身份（`ek + md5(encfilekey)`），要求被请求 ≥3 次才入队；同一条可能两套身份并存，需双标记防重复。
- 解密实证（`pkg/scraper/wxchannels/decrypt.go`，源自 Hanson/WechatSphDecrypt）：响应头 `X-encflag:1` / `X-enclen:131072`，**前 128KiB 加密、其后明文**；密钥流是 **ISAAC64 PRNG**（种子 = `decodeKey` 整数，256 字节 S 盒 + 四轮 mix），对前缀按 8 字节一组异或；不是简单 seed-XOR（与我们早期本地异或还原失败一致）。`X-enclen` 取 HEAD 响应头，`<1024` 或 `>4MB` 回退 131072；带 Range 的请求该头不可信。
- 拼接校验：`内存明文头(131072) + 密文[131072:]`；结构闸门（首 box=ftyp、moov 结束不超文件长、mdat 末尾与实际长度差 ≤ max(64KB,0.5%)）；整段头 MD5 去重；全片解码 0 错误才落盘；`non monotonically increasing dts` / `Application provided invalid` 两类不计错。
- 硬限制（与我们实测一致）：内存只保留**最近播放过**的视频明文头，没播放/没悬停解码就没有明文头；批量下载仍需界面自动化触发起播。

**wechat-mp-tools（Python Flask + Playwright + mitmproxy，多平台工具箱，`D:\github_download\wechat-mp-tools`，v2.3.8，2026-11-17 仍在更新）**：

- 视频号取流两条路：① **分享链接解析**——持腾讯元宝 `hy_token` cookie 调 `yuanbao.tencent.com/api/weixin/get_parse_result`，从 `playable_url` 取 `eid + generalToken`，再 POST `channels.weixin.qq.com/finder-preview/api/feed/get_feed_info` 拿 `feedInfo.videoUrl/h264VideoInfo/h265VideoInfo + decodeKey`；无元宝凭证时回退第三方 Cloudflare Worker 中继（`sph.litao.workers.dev` 等）。② **H5 MITM 注入**——代理 `channels.weixin.qq.com` / `res.wx.qq.com`，移植 wx_channels_download 的 WXU 事件总线 + bundle hook（`finderInit/finderPcFlow/finderGetRecommend/finderGetCommentDetail/finderUserPage`），等 App 内部解密后把含 `media.decodeKey/url/urlToken` 的 feed 抛回本地后端；作者页翻页走 hook 出的 `WXU.API.finderUserPage`。
- 解密：`backend/channels.py` 内置 Python ISAAC64，`int(decrypt_key)` 作种子，前 131072 字节大端 8 字节异或，流式下载落盘后原地解前缀——与我们 `probe-isaac-verify.py` 同算法，可作引擎分支对照实现。
- **与本项目无关/已堵死的部分**：无 MM 客户端内存读取、无 20302 `stodownload` 捕获、无密封参数复放；`windows/win_window.py` 仅窗口枚举/置顶辅助。H5 注入与 res-downloader 同类，4.2 liteapp 原生化后同样失效；其移植计划文档自承 feed 接口是加密/protobuf，`fetch.clone.json()` 解不出明文，必须靠 bundle hook 等内部解密后抛事件。
- **路线边界**：分享链接路线需要元宝登录 cookie + 一条 `sph` 分享/预览入口，**不能枚举 MM 已登录账号的作者作品列表**；第三方 worker 中继是外部服务，本地不可复现。
- **可借鉴点**：web feed 模型确认同体携带 `decodeKey`（印证 L1 材料假设）；`get_feed_info` 接口形态记入 web 侧备选（前提是拿到 web 会话/分享入口）；Python ISAAC64 实现可对照。其文档自承两个未真机验证隐患：sync-feed 扁平/原始 feed 字段路径不匹配可能整批落 0 条；`export{` 多次替换有白屏风险。

**对本项目的可借鉴点**：ISAAC64 前缀解密算法与 `X-enclen` 判定（可对照我们 `dl_engine` 的解密实现）；内存头结构闸门与多候选隔离校验；`m`/`encfilekey` 双身份与 ≥3 次请求阈值用于区分起播条与预加载条。**不可借鉴/已被堵死**：H5 bundle 注入与本地 WS 桥接在 4.2 liteapp 原生链路不成立；三者都没有离线复放 MM cgi、也没有本地造 `token/basedata/sign/svrbypass` 的能力。

**ISAAC64 自解密本地实证（2026-11-17）**：按参考 `decrypt.go` 移植 Python 版（`tools/probe-isaac-verify.py`），用磁盘上仅存的两条 `finder_videoCache_*` 分片 + IndexedDB 记录里的 `seed`（=decodeKey 十进制整数）验证：

| 分片 | seed | 解密结果 | ffprobe |
|---|---|---|---|
| `2d269579da8901dc` | 1030789765 | `ftyp@4` / `moov@32`，头 `0000001c6674797069736f6d…` | 1080×1920 视频 + 音频，时长 260.27s |
| `336ad0397b7cdf0b` | 1816722924 | 同上 | 1920×1080 视频 + 音频，时长 204.31s |

- 算法确认：`decodeKey` 十进制串 → uint64 种子；ISAAC64 PRNG（256 字节 S 盒 + 四轮 mix）生成 8 字节大端密钥流，对前 `X-enclen`（默认 131072）字节逐字节异或；其后为明文。**不是简单 seed-XOR**（解释早期本地异或还原失败）。
- 意义：拿到 `seed + 密文前缀` 即可在**不依赖内存明文头**的情况下还原可解析头；这是对现有 `dl_engine`「纯内存头拼接」路线的一条备选解密路径。
- **seed 留存链路（方向 1，已落地）**：`probe-xworker-full.py` 重新解析 xworker leveldb 全部文件（log+ldb），按 feedId/videoKey 去重留最新，写 `videocache_records.json`；`card-resolve.py` 建 `feedId(oid) → encfilekey → m` 三级索引，`seed_for()` 回表，输出行带 `seed/seed_src/video_key/pre_len/total_len/seed_ek/seed_m`；`wx-viewer.py` 槽位合并保留 seed（新快照带 seed 则覆盖，不带则沿用旧槽位），下载库记录一并留存，调试面板显示 seed 来源。`refresh.py` 编排已把 VC seed 解析排在回表解析之前。
- **现存覆盖限制**：seed 只在**预下载/悬停过**的条目里有 IndexedDB 记录；当前浏览批次若未被微信预取，VC 快照里就没有对应 oid/ek/m，回表命中为 0（实测 24 条缓存记录，当前会话卡片 0 命中）。要扩大覆盖，需在采集环节直接留存 A 响应 `media.decodeKey`（依赖任务 #4 抓原始响应体），而不只靠事后解析缓存库。
- **待办（方向 2，暂缓）**：`dl_engine.py` 仍无 seed 解密分支；拿到 seed 后需在内存明文头缺失时走 ISAAC64 解前 131072 字节兜底（探针 `probe-isaac-verify.py` 已验证算法）。
- 未解除的卡点不变：自解密只替代「内存明文头」这一环，**密封流 URL 仍须微信在场取得**；本地仍不能离线造 `token/basedata/sign/svrbypass`。

#### 2B.7 公开 H5 preview（`/sph` 短链）实测（2026-11-17）

样本：`https://weixin.qq.com/sph/AjeIzXLWMS`（作者「袁希报告」）。链路与返回已实地抓取，探针 `tools/probe-sph-share.py`，原始响应 `work/sph_shortUri_raw.json`，前端包 `work/preview-js/`。

- 短链 301 → `https://channels.weixin.qq.com/finder-preview/pages/sph?id=AjeIzXLWMS`；页面是 SPA 壳（2.6KB），JS 入口 `res.wx.qq.com/.../finder-preview/res/assets/feed.*.js`、`merlin.*.js`、`mmfinderopenwebapisvr.*.js`。
- 接口：`POST /finder-preview/api/feed/get_feed_info`。`/sph` 页用 `shortUri`（短 id 经 `P()` 转换；实测原始短 id 直传即被接受），`/feed` 页用 `exportId`；`baseReq.generalToken` 来自 query/cookie，匿名时为空串。
- **匿名 `shortUri` 实测 201 / errCode 0**，返回：
  - `feedInfo`：`description`、`likeCountFmt/favCountFmt/forwardCountFmt/commentCountFmt`、`createtime`、`isHardAd`、`coverUrl`（`/251/20304/` 封面，带 `encfilekey+token`）、`picInfo[]`；
  - `authorInfo`：`nickname/headImgUrl/authIconUrl`（**匿名无 username**）；
  - `sceneInfo`：`dynamicExportId`（`export/UzFf…`）、`expiredTime`、`commentScene/requestScene/entryScene/entryCardType`；
  - **无** `videoUrl/h264Url/h265Url/h264VideoInfo/h265VideoInfo/decodeKey/id/oid/objectNonceId`。
- 用 `dynamicExportId` 走 `exportId`、空 token 复测：`errMsg.type=2`，标题「此内容暂时无法播放」，不返回任何材料。
- 参考仓库期望的流字段（`feedInfo.videoUrl / h264VideoInfo.videoUrl / h265VideoInfo.videoUrl / decodeKey / id`）只在持有有效 `generalToken`（元宝 cookie 换 `eid+token`）时出现；匿名公开 H5 是**元数据 + 封面**级别，不提供点播源。
- 二维码：前端本地 qrcode 渲染，内容是 `https://channels.weixin.qq.com/mobile/commonFinderJsApi.html?api=openFinderView&extInfo=<JSON {action:"openFinderFeed", feedID:dynamicExportId, notGetReleatedList:1, commentScene, popWebView:1, feedEnterActionType}>`；原生 scheme 为 `weixin://biz/finder/openFinderFeed/<encodeURIComponent({exportId,actionType})>`。**二维码只携带回跳导出 id，不含流地址/密钥**；扫码在微信会话内打开，等价于回到 MM 授权链路。
- 边界：该入口是「单条分享」视角，不能枚举某作者作品列表；匿名响应连作者 username 都不给。公开 H5 路线对本项目的价值仅限于：按分享短链补标题/封面/点赞文案做登记，**不能绕过 hover/在场授权拿到 20302 流**。

#### 2B.7.1 更正：Windows 微信内链是真实播放闭环（用户实测，2026-11-17）

外部浏览器（Chrome/Edge）打开 `/sph` 时看到的是二维码和“长按扫码前往微信观看”，这是
**无微信 UA / 无 WeixinJSBridge** 的分支；不能据此判定 Windows 微信不能播放。

用户实测的 Windows 闭环：

```text
/sph 短链
→ 粘贴到 Windows 微信聊天窗口
→ 微信把 URL 识别成可点击链接
→ 点击链接
→ 微信内嵌浏览器加载 /sph
→ 检测到 WeChat UA，走 WeixinJSBridge
→ openFinderView({action:"openFinderFeed", feedID:...})
→ 唤起微信原生视频号播放器并播放
```

因此：

- **Windows 微信内可以播放 `/sph` 分享链接**，这是一个真实闭环；
- 外部 Chrome 仍是二维码页，不能播放；
- 播放链路仍走微信会话，**不等于**能拿到 20302 密封 URL；
- 要下载仍需在播放后从主进程/内存取 `oid ↔ 完整 URL` 和明文头；
- 每条视频需要各自的分享链接（`FinderGetFeedH5Url` / cmdid 22299），列表材料里没有 shortUri；
- 仍是逐条、占桌面、需要粘贴/点击，不是离线批量 non-hover。

**对本项目的价值**：可以作为一种“按分享链接精确激活某条视频”的备选入口，尤其适合卡片网格里找不到、或 hover 不稳定的单条视频；但它不解决批量链接获取和密封 URL 的离线生成。
#### 2B.8 shortUri 能否作为「流 ↔ 卡片」配对主键（假设评估，2026-11-17）

假设：既然扫码能在微信内拉起播放，说明存在 `shortUri + 用户信息 → 视频` 的半公开接口；若 shortUri 能和取流 URL 对应，就能解决播放窗口与流错配。逐条实证后判定：**shortUri 不是本项目配对问题的解歧义主键**。

- **shortUri 是服务端签发的不透明分享码**，不能由 oid/nonceId 本地推导。MM 内生成入口是 `FinderGetFeedH5Url`（cmdid 22299，scope `finderInteraction`），前端 `670.js` 复制链接时以 `objectId` 调它换 `feedH5Url`；列表材料（A 响应）里不带 shortUri。
- **匿名接口不回身份主键**：`shortUri` 匿名响应里没有 `id/oid/objectNonceId`，无法把 shortUri 反查回 MM oid；流字段（`videoUrl/h264VideoInfo/h265VideoInfo/decodeKey`）只在带有效 `generalToken` 时出现。
- **token 门禁不在 MM 会话内**：`generalToken` 由元宝 web 会话解析（`yuanbao.tencent.com/api/weixin/get_parse_result`，匿名实测 401）；MM 前端包（28e）静态普查无 `generalToken / finder-preview / get_feed_info / sph`，即 MM 前端不向本地下发这个 web token。
- 参考实现的下载方式：preview `videoUrl` 裸 GET（浏览器 UA，不带 cookie/Referer），前缀用 `decodeKey` 走 ISAAC64 解密；该 URL 是否复用 MM 20302 的 `sign/svrbypass` 密封件、还是 web 会话另签的 CDN 地址，**尚无带 token 样本可验证**。

**为什么它解决不了现有错配**：

1. 要给列表里每张卡配 shortUri，必须逐对象在 MM 内调 22299 生成分享链接——这是又一次逐卡原生触发，成本不低于 hover，且 shortUri 不在 feed 材料里可直接读。
2. shortUri → 流地址仍被 web token 门禁；即使拿到，preview 地址与 MM 内 20302 ready URL 是否同源、同密封、同码率都未证实，不能默认等价。
3. 它无法解释 MM 内「划过多张卡、多条同时预加载」的并发场景；流量与卡片的歧义只能靠 renderer feed 对象同体材料（oid + 文案/时长/点赞/媒体）锚定，shortUri 不参与这个并发判定。

**有限可用场景**：已知一条现成分享链接时，持有有效 web token 可作为 MM 密封 URL 过期/失败后的备选下载源；匿名态仅用于补标题、封面、互动数登记。

**待验证（需要一份带 token 的真实响应样本）**：`feedInfo.id` 到底是 MM oid 还是 exportId；preview `videoUrl` 的路径与密封参数构成、码率是否原画；`generalToken` 有效期与作用域；MM 内打开 H5 预览页时 query 是否曾携带可复用 token（前端只读 `query.token || cookie token`）。

**2B 闸门**：仅凭 `oid`（+ L1 材料）经一次可复放请求拿到 206 可下载 URL；若授权必须微信在场触发，则 L2 暂不成立，non-hover 只完成 L1 列表层。

### 2C 会话鉴权与协议复放

离线复放 MM cgi 需要补齐：

- 会话凭证：session token / skey / 用户标识；
- 设备指纹与端类型位；
- MM 协议帧封装、加密与签名头；
- 密钥来源：主进程内存 / 配置 / 加密 DB。

**2C 闸门**：Python 侧离线重放 6624，返回与在线一致的 `originalCount` + 首批 `object[]`（时长/点赞指纹对上）。

---

## 5. 关键未知问题清单（逐条待答）

| # | 问题 | 验证方式 | 现状 |
|---|---|---|---|
| Q1 | finder cgi 走哪条 TCP / 主机 / 端口？是否过系统代理？ | 启动 mitm 通读主机清单 + 枚举 Weixin/AppEx 外联端点 | **已答**：仅主进程一条直连 `:80` 长链；微信对系统代理端口零连接、旁路代理；renderer 无外联。系统代理模式 mitm 不可见 |
| Q2 | A 响应 `media.url/urlToken/decodeKey` 与 B 20302 URL 的字段映射？`urlToken` 能否直接取流？ | 拿到一份完整 A 响应后逐参数比对实测 | 部分已答（静态+缓存键/URL 普查）：A 带 `url/urlToken/decodeKey/spec` 及基址 query 的 `encfilekey/m/uzid/hy/idx/X-snsvideoflag`；B 独有 `token/basedata/sign/svrbypass`；代码确认 `urlToken` 拼进 videoUrl，**≠ B 的 `token`**；缺原始 A 响应体逐值比对 |
| Q3 | 20302 密封参数是列表响应就带，还是 hover/播放时另一次授权 cgi 签发？ | 对比首次进入主页与 hover 后的内存/抓包差集 | 部分已答：`encfilekey/m/uzid/hy/idx/X-snsvideoflag` 随 A 材料到；`token/basedata/sign/svrbypass` 不在前端代码与缓存键里，原生侧后续阶段取得；产生方式（CDN 302 / native-only 授权 cgi / 混合）待原始响应或协议包确认 |
| Q4 | 授权 cgi 是否依赖 xplayer / 播放器实例或 UI 状态？ | 无播放器在场时离线触发授权请求观察返回 | 部分已答：前端无按 feedId 取流/换地址的 cgi；预下载/起播由播放器组件内部在 preview-start/悬停态发起；是否必须 xplayer 实例在场静态不能证伪，倾向需要起播阶段触发 |
| Q5 | MM 协议帧加密/签名用什么密钥，能否从内存提取并在 Python 复放？ | 主进程协议段逆向 + 密钥定位 | 未答 |
| Q6 | finder 缓存 DB 哪些表存 feed 对象，密钥是否常驻内存可提取？ | DB 文件枚举 + 内存密钥探针 | 部分已答：无 finder 命名独立库；20 个业务库全加密、空闲页无 oid/标题残留；`key_info.db` 明文存 124 行 180 字节包裹 blob（结构未反解）；CEF 本地存储唯一 finder 记录是 xworker `videoCache` 表（24 feedId，仅部分密封件+加密前缀，无元数据/完整 URL）。加密库表与密钥提取未做 |

---

## 6. 探索顺序、成本与风险

| 步骤 | 观测点 | 预期产物 | 成本 | 主要风险/被堵点 |
|---|---|---|---|---|
| 2A.1 代理增强 | ~~系统代理 mitm~~（已证旁路，关闭）；仅剩透明代理/WFP 驱动 | cgi 主机/路径 + 非媒体 body | 高（内核级） | 微信直连长链、不走 WinINET 代理；MM 自有加密帧；影响面大 |
| 2A.2 内存平铺扫描 | ~~ASCII/UTF16 字符串差分~~（已证取不到值，关闭）；剩余 V8 对象图遍历 | 当前批次 object_id ↔ 媒体材料记录 | 高（对象图） | 值在压缩指针后；protobuf/V8 布局随版本变；旧会话残留干扰 |
| 2A.3 调试端口 | ~~exe 包装注入~~（已证被清单 MD5 自检自愈还原，关闭）；剩余仅运行时 DLL 注入 detour CreateProcess | renderer 完整 feed 模型对象 | 高（注入/反篡改） | 文件层被签名清单拦截；运行时注入有账号/兼容风险；evaluate JS 可能被设置禁用 |
| 2A.4 SQLCipher / 本地存储 | ~~CEF leveldb/IndexedDB~~（已扫：元数据与完整 URL 零明文，仅 xworker videoCache 部分密封件缓存）；剩余加密库需反解包裹密钥 | 已缓存 feed 对象 / 本地可复用前缀 | 高 | 业务库全 SQLCipher；密钥 blob 结构未反解；缓存分片会淘汰、前缀非简单 seed 异或；无 finder 命名独立库 |
| 2A.5 前端调用链拆解 | ~~静态读码~~（已完成：hover=前端事件→内部 `getVideoInfo` 预下载；桥无 feedId 取流命令，`preloadVideo` 按 URL 预取、`previewVideo` 为相册预览）；剩余 renderer 内 JS 执行入口 | 可程序化触发的内部函数/入口定位 | 高（注入/对象图） | 内部函数闭包在 V8 模块内；无桥命令可伪造；触发仍需 A 材料与在场签发 |
| 2B 授权映射 | ~~静态字段映射/cgi 普查~~（已完成：A↔B 参数归属表、97 条 cgi 注册表；列表 cgi 全返回 object[]，无单条换地址接口）；剩余原始 A 响应比对 + 密封件产生方式判定 | 材料→地址映射表 + 离线换取可行性结论 | 中→高 | 密封件仍需服务端签发；产生方式（302/native cgi）未明；授权倾向绑定播放器在场 |
| 2C 协议复放 | 主进程协议帧/密钥 | Python 可复放的 6624 请求 | 高 | 协议加密/签名不透明；凭证会过期 |

**推荐起步**：2A.1 系统代理、2A.2 平铺扫描、2A.3 exe 包装、2A.4 本地持久层均已实测关闭或受限；2A 剩余可行观测点只剩 V8 对象图遍历、运行时 DLL 注入、内核级透明代理这类高成本手段。2B/2C 在 L1 材料到手后再评估；当前证据不支持纯离线取流。

---

## 7. 与现有任务 / 文档的对应

- 任务 #4：抓 feed 页面/接口响应体，验证 `exportkey/oid/nid ↔ 标题` 映射（对应 2A.1/2A.2）；
- 任务 #10：代理迁移与旧 PS1 界面退役；
- 任务 #13：多账号 profile 层选择与卡片隔离（离线复放同样需要按账号隔离会话凭证）；
- `card-url-binding.md` §5.3：本地拼 URL 的参数缺口与密封件清单；
- `association-research.md`：§9.2 cgi 表与通道、§16.34 主页接口请求/响应结构、§16.39 本地拼接与桥接结论、§16.42 内存分层评估。

---

## 8. 当前结论

- 路径 1 已落地但占桌面；non-hover 短期最可能先突破 **L1 列表材料离线获取**；
- 本轮已证：平铺字符串扫描（renderer + 主进程）取不到 L1 材料值，字段名只在源码/描述符/schema 块，值在 V8 指针后或解析前的原始响应里；
- **2A.4 已收尾**：业务库全加密、空闲页无 finder 明文；CEF 本地存储不落卡片元数据与完整密封 URL，仅 xworker `videoCache` 缓存 24 个 feedId 的部分密封件与已淘汰的加密前缀；`token/basedata/sign/svrbypass` 本地不存在；
- **2A.5 已收尾（静态读码）**：hover 不是可独立复放的原生系统调用，而是前端事件→内部 `getVideoInfo(feed)` 预下载（fetch 前缀 + `lite.file` 写缓存）；原生桥无按 feedId/oid 取流或换取地址的命令；唯一相关的 `preloadVideo({url,ratio})` 是问问包按已有 URL 预取、`previewVideo` 是相册预览，视频号播放窗口二者都没调；跳过 hover 只能靠 renderer 内 JS 执行入口（注入/对象图），且不解决材料与密封件缺口；
- **2B 静态普查已完成**：A 材料（`url/urlToken/decodeKey/spec` + 基址 `encfilekey/m/uzid/hy/idx/X-snsvideoflag`）与 B 密封 URL 的参数归属已逐条映射；97 条 cgi 全量解析，列表类接口都返回 `object[]`，`FinderStream(8060)` 也是流列表而非单条换地址；前端代码无 `stodownload/encfilekey/svrbypass/basedata` 签发逻辑，密封件 `token/basedata/sign/svrbypass` 由原生侧后续取得；剩余待证：密封 URL 是 CDN 302 还是 native-only 授权 cgi，需原始 A 响应/协议包（2C、任务 #4）；
- 剩余 2A 观测点：V8 对象图遍历（高成本）、运行时 DLL 注入 detour CreateProcess（高摩擦/账号风险）、内核级透明代理/WFP（高影响面）；加密库反解包裹密钥属最后手段；
- **L2 免触发下载地址**成本高、不确定：密封件必须服务端签发，授权倾向绑定播放器起播在场（Q3/Q4 部分回填，待原始响应实证）；官方公开文档（2B.5）无作品列表/源地址接口，公开 access_token 体系与私有 MM 协议不互通；
- 在 2B/2C 打通之前，下载仍需微信在场取流；现阶段不承诺本地无交互下载。
