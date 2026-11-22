# 已知问题与解决方案

> **DeepSeek Harness** · 文档整理与验证

更新：2026-11-16  
适用：微信 4.2.x Windows / WeChatAppEx / PowerShell 7（HUD 也兼容 5.1）  
当前版本：`ecd316a`

图例：

- ✅ 已解决
- 🟡 有缓解，未彻底解决
- 🔴 未解决，需要明天继续测
- ⛔ 已知限制，暂时无法可靠解决

---

## 1. Hover 候选 URL 选错，封面出现但下载失败

**现象**

- hover 后卡片能绑定、封面能出现、条目进入界面；
- 下载后实际文件时长与卡片时长不符；
- 例如卡片 `02:38`，下载到的却是 `204.8s` 的视频；
- 日志：

```text
时长 204.8s 与卡片 158s 不符
```

**原因**

`recentMedia` 里同时有当前视频、上一条、预加载下一条。旧逻辑按“最早开始”选，容易选到预加载或上一条。

**当前处理**

- 优先选带 `m=` 的候选；
- 再按已下载 Range `MaxEnd` 从大到小排序；
- 下载时把卡片时长传给 `wx-dl`；
- `wx-dl` 下载后如果实际时长与卡片差超过 3 秒，直接拒绝保存；
- 结构闸门必须是 `ftyp / moov / mdat`，结尾误差从 64KB/0.5% 收紧到 1KB/0.02%。

**仍未解决**

- 仍然是在候选里“猜”哪条是当前视频；
- `MaxEnd` 更大不保证就是目标；
- 预加载的下一条可能比目标更大；
- 没有真正把 URL 和内存文件头一一配对。

**可能方案**

1. 按内存头做候选筛选：解析 `mvhd` 时长，只保留与卡片时长一致的 header；
2. 对每个候选 URL 在对应 header 的 `moov_end` 做 Range 16；
3. 只有 URL 与 header 结构一致，且 header 时长与卡片一致，才下载；
4. 把 header MD5 作为主键，而不是 URL/时间/请求顺序；
5. 长期方案：接入 issue 作者的内存 URL 扫描 + header 配对，弱化甚至去掉代理依赖。

**优先级：高**

---

## 2. Hover 有时完全不进界面

**已确认的原因**

### 2.1 停留不足 1 秒

日志只有 `hover-start`，没有 `hover-dwell`。

处理：

- 默认停留 1 秒；
- 预览盖住卡片时继续按上一张卡矩形计时；
- 但仍建议在同一张卡上停 1.2–2 秒。

### 2.2 有停留，但 0 个媒体候选

日志：

```text
hover-dwell ...
hover-cands 
```

原因：

- 微信使用本地缓存，不再发 `stodownload`；
- 监听/代理没有运行；
- 页面预加载请求被合并。

处理：

- 新增 `work\card_media.json`，按卡片 key 保存 URL 约 2 小时；
- 清缓存不会删除；
- 重新 hover 时可以直接用旧 URL 建条目；
- 下载前仍会做 Range 预检和时长校验。

### 2.3 卡片绑定了，但条目没进界面

旧版在写 library 之前先截封面、HEAD 查大小；任何一步慢都会导致条目延迟或丢失。

已改为：

1. 先写 library（ID/时长/URL/状态）；
2. 再补封面和大小。

### 2.4 HUD 抛异常

曾经 `$status` 变量覆盖 TextBlock，绑定后每次 `$status.Text` 都抛：

```text
在此对象上找不到属性“Text”
```

已修复（`e6f2c34`）。

### 2.5 监听/代理已经停止

日志会显示：

```text
listener stopped
mode=background
```

此时 HUD 仍能识别卡片，但不会有新地址。

**仍未解决**

- 微信本地缓存时，旧 URL 可能过期；
- `card_media.json` 只保留 2 小时，TTL 未实测；
- 卡片 key 仍包含文案，文案变化会导致缓存 miss。

**优先级：高**

---

## 3. 怀疑腾讯对 hover 限流

**结论：目前没有证据，不能确认。**

已有日志显示：

- 未入库的 hover 中，多数是 `mode=page`；
- 部分是停留不足 1 秒；
- 部分是 `hover-cands` 为空；
- 最近一次“不响应”实际是 `listener stopped`，采集链路已停，不是服务端限流。

**仍可能的限流表现**

```text
mode=page
hover-start 正常
hover-dwell 正常
hover-cands 连续为空
```

表示 HUD 看到卡片，但微信没有发出新媒体请求。

**明天的判定实验**

1. 确认 GUI/监听/代理都在运行；
2. 同一张卡 hover 10 秒；
3. 记录 `mode` 和 `hover-cands`；
4. 不响应后等 2–5 分钟再试；
5. 对比“重启 HUD 立刻恢复”与“等待后恢复”；
6. 若只有等待才恢复，才更像客户端/服务端节流。

**优先级：中，先排除本地因素**

---

## 4. 第一次下载失败后很难恢复

**当前行为**

- 失败后条目进入“待重播”；
- 旧逻辑只在 library 收到新 URL 时才重试；
- HUD 对已经绑定的卡片不会主动刷新 URL；
- 实际日志里 6 次失败全部：

```text
是否重试=否
结果=未恢复
```

**已加的缓解**

- 失败后 12 秒，自动用同一 URL 重试一次；
- 日志：

```text
download-retry id=... attempt=1
```

**仍未解决**

- 如果第一次失败是因为 URL 本身是错的，重试同一 URL 仍然失败；
- 没有“换下一个候选 URL”的机制；
- 没有在失败后主动清除 HUD 的 cardMedia 映射，下一次 hover 可能继续用旧 URL。

**可能方案**

1. 失败后写 `work\rebind.json`，HUD 删除对应 cardMedia，下一次 hover 强制重新绑定；
2. 保存候选 URL 列表，失败后按顺序换候选；
3. 失败原因分类：过期、无头、时长不符、结构不符，不同原因走不同恢复；
4. 对“无头/预检超时”延迟重试，对“时长不符”直接换候选。

**优先级：高**

---

## 5. Range 预检过慢/超时

**现象**

日志中两次 `Range 预检` 相隔 60 秒以上，GUI 判失败。

**原因**

预检先扫内存头，再对每个头发 Range；扫描/转储本身可能很慢，之前的 10 秒截止只限制探测阶段。

**已处理**

- 预检扫描也纳入 8 秒截止；
- 最多扫描 10 个头；
- 最多探测 5 个；
- 单个 Range 超时 3 秒；
- 超时后返回 `skip`，不再阻塞整条下载。

**风险**

- 超时跳过后仍可能下到错误密文；
- 严格时长校验会拒绝，但会表现为失败；
- 目标头排在后面时可能被跳过。

**优先级：中**

---

## 6. 代理抓到错误 URL / 同一 encfilekey

issue 作者反馈：代理记录 5 条，`encfilekey` 全部相同，都是另一条视频，目标视频根本没出现。

**当前处理**

- 不按代理记录顺序对应视频；
- 用 Range 16 在 `moov_end` 处判断地址与头是否结构一致；
- 不匹配不下载整条；
- 下载后校验时长和顶层 box。

**仍未解决**

- 代理完全没抓到目标 URL 时，预检也无从开始；
- 需要内存 URL 扫描作为兜底。

**可能方案**

按 issue 作者脚本：

- 扫 `WeChatAppEx.exe` 内存中的 `stodownload` 地址；
- 过滤 `X-snsvideoflag`；
- 用 `encfilekey` + `X-snsvideoflag` 去重；
- 对每个地址用 Range 16 配对内存头；
- 输出 JSON manifest（header MD5、时长、URL、文件）。

**优先级：高（长期）**

---

## 7. 文件头 / 密文结构判断

issue 提供的两条样本：

```text
3:47   ftyp 28 / moov 189085 / free 8 / mdat 40343309
7:09   ftyp 28 / moov 474271 / free 8 / mdat 38314888
```

都已验证：

- `moov_end` 都大于 131072；
- 在 `moov_end` 处正好是 `free`；
- 顶层 box 结尾精确等于文件大小。

**已处理**

- 必须出现 `ftyp/moov/mdat`；
- 容差收紧到 `max(1KB, 0.02%)`；
- `mdat` 必须存在。

**风险**

- 某些封装在 `mdat` 后有 padding/free，会被误杀；
- 回退点：

```text
before-strict-box -> 530ab4f
```

**优先级：低，观察误杀**

---

## 8. 封面与 Windows/微信不一致

**已确认**

当前样本没有内嵌封面：

```text
attached_pic=0
covr 不存在
```

Windows/微信显示的是首帧，不是文件内指定封面。

**已处理**

取封面顺序：

1. 内嵌 `attached_pic`；
2. 精确首帧（0 秒）；
3. Windows Shell 缩略图；
4. 旧版播放器封面自动重抽。

**仍未解决**

- 有些视频首帧是黑帧/过渡帧，可能仍和微信显示不同；
- Shell 缩略图有缓存；
- 卡片来源的封面和文件抽帧可能不同，这是正常的。

**优先级：低**

---

## 9. 误显示“已下载”

**原因**

旧逻辑按输出文件名里的时长匹配，同一时长的其他视频会误报。

**已处理**

- 删除 `Find-Downloaded` / `filesByDuration` / `Refresh-Index`；
- 徽标只在“卡片已绑定媒体 ID”且索引里有相同 `m`/`encfilekey` 时显示；
- 没有绑定 ID 的卡片不会仅凭时长显示已下载。

**副作用**

- 本次运行中没 hover 过的已下载卡片不会显示 ✓，直到绑定一次。

**优先级：已解决**

---

## 10. 清缓存后旧内容回来

**已处理**

- `work\cache_epoch.txt`：清缓存时间点；
- GUI/HUD 忽略早于 epoch 的 library 条目；
- 清空 `flows.log` 并复位 flow offset；
- HUD 15 秒内禁止磁盘旧条目合并；
- 5 秒内暂停自动采集；
- 不删除输出目录视频。

**仍未解决**

- 如果旧版 HUD 还在运行，仍可能写回；
- 必须完整重启工具；
- `card_media.json` 会保留（这是有意的），其中 URL 可能过期。

---

## 11. 重复 HUD / 代理被其他程序改回

**已处理**

- HUD 增加单实例互斥量，第二个实例直接退出；
- 监听进程每几秒检查系统代理，被 v2rayN 等改回时重新指向 `127.0.0.1:8898`。

**注意**

- 监听进程如果被强杀，watcher 可能来不及还原代理；
- 需要检查 8898 是否真的有进程监听。

---

## 12. 标题

**已按产品决定移除**

- HUD 不获取卡片文案作为 title；
- library 不保存 title；
- GUI 不显示 title；
- 旧 `title` 字段在 HUD 启动时删除；
- 界面显示“文件名”。

**限制**

- 不能再靠标题识别视频；
- 只能用 ID、封面、文件名、时长；
- 同一时长多条时人工辨认更难。

**优先级：已按需求关闭**

---

## 13. 播放窗口连续播放会下载全部预加载

**不是 bug**

- 播放窗口模式设计为自动下载所有正在播放/预加载的视频；
- 因此界面可能一次增加很多条目；
- 只想要少量视频时用 hover + 手动下载。

---

## 13.1 wx-viewer：扫描时没有主窗口 / 卡在 pending

### 现象

双击 `wx-viewer.vbs` 后，微信页面自动滚动，但 viewer 主窗口半天不出现。

### 原因

`start_scan()` 会先 `withdraw()` 主窗口，避免遮住视频号卡片，保证封面截图正确；扫描还要依次做：

```text
UIA 全量滚屏
renderer 堆扫描
主进程完整 URL 扫描
resolve 绑定
```

旧版没有进度窗口，看上去像没启动。

### 处理

- 现在扫描时显示左上角「视频号扫描」小窗，实时显示页数/阶段；
- 扫描完成或失败后自动关闭小窗并恢复主窗口；
- 10 分钟内的 `mem_model2.json` / `main_pairs.json` 会复用，避免每次重扫 2–3 分钟；
- 如果主窗口仍不出现，检查 `viewer/work/viewer.log` 最后一行停在哪个阶段。

### 找不到卡片时看什么

现在定位失败会写一条诊断，而不是只有“找不到这张卡”：

```text
当前账号 / UIA 总卡片数 / 可见卡片数
同时长候选数 / 时长+点赞候选数 / 同文案候选数
最接近的 3 个候选（时长|点赞|文案）
```

常见处理：

1. 微信是否仍在**该作者主页**（账号名是否一致）；
2. 手动把目标卡滚到视口，再点下载；
3. 目标卡必须与 `duration|like|desc` **完全一致**；不做前缀/近似匹配，避免下错卡；
4. 目标卡已不在当前列表（删稿/换号）时，重新扫描；
5. 仍失败则查看 `viewer/work/viewer.log` 的候选，而不是连续点下载。
### pending 点击后仍失败

`pending` 行点击会：

```text
定位卡片 → hover 8 秒 → 重扫 renderer → 重扫主进程 → resolve → 下载
```

仍然失败通常是：

- 该卡片没有被微信加载/悬停到；
- renderer 里没有该 `index/oid`；
- 主进程还没有这条 `oid ↔ 完整 URL`；
- URL 缺 `sign/basedata`，或已过期（HEAD 400）；
- 明文头被挤出内存（需要重新 hover 8 秒）。

处理：刷新列表、重新 hover 该卡 8 秒，再点下载；不要连续快速切换很多卡。

### 切换账号后列表没变

点一次「重新扫描」：

- 清空当前列表和页码；
- 忽略 10 分钟缓存，强制重扫 renderer 和主进程；
- 新账号的卡片会替换旧列表；
- `library.json` 里旧账号的记录按 `account` 字段隔离，不会把旧下载状态套到新账号。

如果切号后不点重新扫描，viewer 仍会显示上一次扫描的列表，这是预期行为。

### 日志

```text
viewer/work/viewer.log
viewer/work/resolved_cards.json
viewer/work/main_pairs.json
viewer/work/mem_model2.json
```

界面底部有「复制日志」「复制最后错误」按钮；日志也可以直接选中复制。定位失败会额外报告：账号、UIA 总数/可见数、同时长/同前缀候选、最接近的 3 个候选，以及“找到候选但滚不到视口”的原因。

### 单任务限制

viewer 同一时间只允许一个下载任务。原因不是网络，而是：

- 只有一个鼠标 hover 位置；
- 只有一套微信滚动/UIA 网格状态；
- renderer/主进程扫描是全局的；
- 明文头是有限缓存，新头会把旧头挤掉。

要做并发，必须拆成「串行激活/取头」+「并行下载」。

### 保存时 console 闪窗

`wx-viewer` 用 `pythonw` 启动，子进程 `pwsh.exe`/`curl.exe` 默认会新建 console，`ffmpeg` 继承后看到窗口。已在 viewer 内使用：

```python
CREATE_NO_WINDOW + STARTF_USESHOWWINDOW + SW_HIDE
```

覆盖 `pwsh`、`curl`、`resolve`；`ffmpeg` 是其子进程，不再单独弹窗。
## 13.2 为什么暂时去不掉 hover（non-hover 结论）

豆包做过一轮完整的 non-hover 探索，结论是**应用层路线已逐项关闭**，详见 [non-hover.md](non-hover.md)。

| 路线 | 结果 |
|---|---|
| 系统代理抓 feed cgi | 失败：cgi 走主进程直连长链，不走 WinINET 代理 |
| renderer/主进程平铺字符串扫描 | 失败：只有字段名，值在 V8 指针后或原始响应里 |
| CEF 调试端口 | 失败：无 `--remote-debugging-port` |
| 本地数据库/IndexedDB | 失败：业务库 SQLCipher；缓存只有部分 videoCache 前缀/seed |
| 本地拼 `encfilekey/m/token` | 失败：缺 `token/basedata/sign/svrbypass`，CDN 400 |
| 右键菜单「播放」程序触发 | 可打开抽屉，但仍是逐卡桌面动作，不签发 URL |
| 按 oid 直接唤起播放器 | 前端桥没有对应 action，外部无法 invoke |
| 后台/多开播放器轮流解码 | 隐藏/非活动播放器会暂停，不产生明文头 |

剩余未证伪的硬路只有：

```text
内存提取 MM 协议帧密钥 → Python 复放 pc_finder* cgi
```

成本高、协议会变、账号风险大，暂不作为近期目标。

**实践结论**：当前继续用 hover 8 秒或播放窗口实际播放；不要反复尝试上述已关闭路线。

**例外：Windows 微信里的 `/sph` 分享链接**

外部 Chrome 打开 `/sph` 只显示二维码，但把同一链接粘贴到 Windows 微信聊天窗口并点击，微信内嵌浏览器会走 `WeixinJSBridge.openFinderView`，可以唤起原生播放器播放。这是真实的单条播放闭环，但：

- 每条视频要单独拿分享链接（`FinderGetFeedH5Url` / cmdid 22299）；
- 仍要前台粘贴/点击，不能离线批量；
- 播放后仍要从内存取 20302 URL 和明文头，链接本身不含这些。

详见 [non-hover.md](non-hover.md) §2B.7.1 和 [player-flow-architecture.md](player-flow-architecture.md) §9。

### seed 自解密（备选，不是 non-hover）

如果 IndexedDB/videoCache 里已经有：

```text
decodeKey / seed + 前 131072 字节密文
```

可以用 ISAAC64 解出明文头，替代“内存明文头”这一环。但它**不能替代密封 URL**：URL 仍要微信在场签发，未预取/未缓存的卡片也没有 seed。

## 13.3 播放窗口后台/多开为什么不能稳定取流

[player-flow-architecture.md](player-flow-architecture.md) 的结论：

- 列表/关联/下一条在主 renderer store；
- 播放器进程只拿当前条的 url + seed + 解码缓冲；
- 多开窗口可以存在，但隐藏/非活动实例会暂停；
- 暂停的实例不实际解码，内存里就没有新的明文头；
- 因此不能靠“后台挂多个播放器轮流解码”批量取头。

播放窗口自动下载（`wx-gui`）仍然有效，但前提是窗口实际可见/正在播放。

## 13.4 连续播放时什么时候可以切下一条

> **前提：必须已经知道哪个任务对应“正在播放的这条视频”。**
> `wx-dl` 的日志是**单个 URL/任务**的，不是播放器全局状态；没有 oid/卡片绑定时，不能拿某条流的 `命中` 去切播放器。

**不要按固定秒数切。** 安全边界是「当前视频的明文头已经复制出来」，不是「播放了 N 秒」。

当前 `wx-dl` 的日志阶段：

| 阶段 | 日志 | 这时能切吗 |
|---|---|---|
| 地址到手 | `下载密文 ...` 之前 | 不能，还没有明文头 |
| 预检命中 | `预检命中：文件头与此地址结构一致` | **仍不能**：当前实现预检后还会重新扫内存，没把匹配头保存下来 |
| 候选已拼 | `命中：pid=... 地址=... 时长=...，全片校验 ...` | **仅当该任务已绑定当前视频时可以**：明文头已写入 `cand_*.mp4` |
| 已保存 | `已保存: ...` / `SAVED=...` | 最安全，但最慢 |

所以：

```text
最快安全切换点 = 当前视频对应的任务出现「命中：pid=...」
最保守点       =「已保存」
```

如果在这之前切：

- 新视频解码会把旧明文头挤出内存；
- `wx-dl` 预检/扫描会变成 `mismatch` 或 `noheaders`；
- 当前视频变 pending，只能重播。

### 想做“更早切换”

需要给 `wx-dl` 增加**明文头快照**：

```text
当前视频任务预检命中
→ 立刻把匹配的 131072 字节头写入 header_<tag>.bin
→ 后续拼接收密文时直接用快照
→ 输出 HEADER_READY
→ 这时就可以切下一条
```

有了快照，切换边界从“候选拼完”提前到“预检命中”，下载可以继续在后台完成。

当前版本尚未实现快照，所以：

```text
预检命中 ≠ 可以切
该视频任务的「命中」 = 可以切
已保存 = 一定可以切
```

## 13.5 多流并发下，不能用一个流的状态去切播放器

播放器在播放/预加载时，内存和 flows 里可能同时存在：

- 当前视频；
- 上一条/下一条预加载；
- 同屏其他卡片的预览；
- 多个播放窗口/抽屉实例；
- 相关推荐队列。

因此：

- 某个 URL 的 `命中` 只说明**这个 URL 找到了结构匹配的头**；
- 它不说明播放器当前播的是哪条；
- 更不能说明“当前视频已经可以切了”；
- 多个 `wx-dl` 任务并发时，谁的 `命中` 都不能单独作为切条信号。

正确的单元是**任务**，不是流：

```text
task_key = object_id（优先）/ uia_key
task.state = url_found → header_ready → downloading → verified
```

只有：

```text
当前播放视频的 oid
→ 对应任务
→ 该任务 header_ready
```

才允许切下一条。

当前实现：

- `wx-dl` 自动模式：按 `m/encfilekey` 收流，**没有绑定当前播放视频**；
- `wx-viewer`：有 oid/index/时长/点赞绑定，但是逐行激活；
- 两者还没有合并成“播放器自动连播 + 每任务 oid 绑定 + 头快照”。

### 实践建议

1. **没有 oid 绑定时，不要根据任何流状态切播放器**；让它继续播，或按 `已保存` 保守切。
2. 批量优先用 `wx-viewer` 的逐行精确激活，而不是连续播放盲切。
3. 如果坚持连续播放：
   - 先通过 renderer/main 把当前条绑定到 oid；
   - 为该 oid 建任务；
   - 任务 `header_ready` 后才切；
   - 其他同时出现的流只入队，不参与切条判断。
4. 要做真正并行，必须让每个任务拥有自己的 header 快照，不能共享“当前内存头”。

## 13.6 2026-11-18 进展：播放器“当前条”绑定仍不可靠

豆包新增了两类探针：

- `b-feed-extract.py`：从 renderer 堆同时按 UTF-8/UTF-16 抽 feed 块，得到 `oid/昵称/文案/media url`，一次快照 91 条；
- `b-player-dump.py`：用播放窗 UIA 的进度文本、主文案、作者回表 feed 表，判断当前条。

实测结果：

```text
windows: 3
current: 本轮快照 unmatched / no-progress（也出现过 matched，但不稳定）
oid: None
```

**2026-11-20 复验（当前播放窗口）**：

```text
UIA: 当前标题=耗时两年… / 作者=我是木子夫人 / 点赞=4.2万
b-player-dump.py --scan
→ feeds: 224
→ pid=26232 progress=None
→ match=no-progress-unmatched
→ oid=None
```

feed 表里有作者 `我是木子夫人` 的其他视频，但没有当前标题这一条；所以“标题+作者回表”仍然失败。

原因：

- feed 表是缓存集合，当前刚切到的条目可能还没入堆/已被换页；
- UIA 播放窗不带 oid；
- 两个播放窗的 feed 块可能混在同一 renderer 堆；
- 只能靠文案/作者/顺序回表，仍有歧义。

所以：

```text
“当前播放的是哪条”目前还不能作为可靠的切条信号。
```

这与 13.4/13.5 的结论一致：没有当前 oid 绑定，就不能用某个流的状态切播放器。

## 13.7 聊天转发卡片：oid + 完整 URL，但不是作者主页列表

`mem-feed.py` 从主进程内存的聊天消息 XML 中解析到：

```xml
<finderFeed>
  <objectId>15045243550007823056</objectId>
  <objectNonceId>...</objectNonceId>
  <desc>...</desc>
  <mediaList>
    <media>
      <url>.../20302/stodownload?encfilekey=...&amp;m=...</url>
      ...
    </media>
  </mediaList>
</finderFeed>
```

价值：

- 转发卡片自包含 `oid + nonce + 完整 20302 URL`；
- 点击卡片走原生 `openFinderFeed`，是精确的单条播放入口；
- 不需要先 hover 卡片网格。

边界：

- 只覆盖**聊天里已转发的卡片**，不是作者主页的完整列表；
- 卡片 XML 只有 URL，没有 `decodeKey/seed`；要明文头仍需实际播放/解码；
- 历史转发残留不代表当前主页；不能拿它批量枚举作者作品。

## 13.8 2026-11-18 突破：seed 自解密（viewer 已接入，wx-dl 尚未）

豆包在 `association-research.md` §16.43 记录了一个重要进展：

```text
kvReport / callRemoteMethod 上报串
→ <oid>,<stodownload URL>,<decodeKey 6–12 位>,14,0,...
→ decodeKey 作为 ISAAC64 seed
→ 解密前 131072 字节
→ 不依赖 WeChatAppEx 明文头
```

实测两条端到端成功：

```text
oid 15050086854154853712  seed 979861605  3,566,401 bytes / 40.22s
oid 15052259438420827465  seed 1575101769 1,499,310 bytes / 20.81s
```

意义：

- 明文头缺失时，seed 自解密可以作为兜底；
- 不再需要“内存里恰好有当前视频的头”；
- 仍需要完整 20302 URL（来自主进程/卡片/report 串）；
- 未取流/未上报的 pending 卡片仍然没有 seed；
- 同一 oid 偶发两条 seed，需要校验裁决。

当前本仓库：

```text
viewer/seed_scan.py + viewer/isaac64.py + viewer/dl_engine.py --seed
已接入按 oid 查 seed、直接自解密下载；实测 40.22s 文件成功
wx-dl.ps1 仍走“扫描内存明文头 + 拼接”路线
```

剩余工作：

1. 扩大 `decodeKey/seed` 覆盖率；
2. 把 seed 分支接进 `wx-dl.ps1` / `wx-gui` 自动链路；
3. 处理同一 oid 多 seed 候选；
4. 只有 URL 没有 seed 的 pending 仍需 hover/播放。

## 13.9 微信 4.2.0.53：UIA 合成滚轮/键盘被隔离

豆包在 4.2.0.53 实测：

| 注入方式 | 结果 |
|---|---|
| `mouse_event` WHEEL | 网格不翻 |
| `SendInput` | 网格不翻 |
| `keybd_event` PageDown/PageUp | 无效 |
| `PostMessage` WM_KEYDOWN/WM_MOUSEWHEEL | 无效 |
| UIA `page-profile` 后代 `ScrollPattern` | 没有暴露 |
| 祖先 `class=content` 的 `ScrollPattern` | **可用，但 Scroll/SetScrollPercent 会 raise 前台**（仅 `find_card` 使用） |
| 无 focus 的 `ScrollItemPattern.ScrollIntoView`（未聚焦/部分遮挡） | **可分页**（v0.2026-11-22 实测 30→180、15→442） |
| 完全遮挡时的静默滚动 | 不触发后续分页（Chromium 原生遮挡检测） |
| 真实鼠标滚轮/PageDown | 正常 |

对本项目的含义：

- `wx-viewer` 的**扫描分页**使用无 focus 的 `ScrollItemPattern.ScrollIntoView`；
- `content.ScrollPattern` 的 `Scroll()` / `SetScrollPercent()` 在本机实测会把微信 raise 到前台，因此扫描路径不使用它；`find_card` 的精确滚动仍保留 `ScrollPattern`；
- **扫描阶段不调用 `SetForegroundWindow`/`SetFocus`**；静默失败时保留当前批次，不再抢前台；
- 部分遮挡/未聚焦的 profile 页面可以静默分页；完全遮挡仍会失败；
- 下载阶段的 `find_card`/hover 仍可能需要 focus，但不会在翻页扫描时主动 raise；
- 手动滚动微信后，再点「重新扫描」可以并入下一批；
- 不要用 `wx-viewer` 做“自动翻完作者主页”的承诺；
- 作者主页全量批量仍应使用 `wx-gui` 的播放器连播。

`wx-gui` 连续播放不依赖这个 UIA 滚轮，所以不受此限制影响。

## 13.10 2026-11-19：viewer 扫描性能优化

参考豆包的 `renderer-scan.py` / root-only main-pair，本仓库的 viewer 已改为：

- `renderer_scan.py`：一次读 renderer 堆，同时抽卡片模型 + `decodeKey/seed`；
- 只扫活跃 renderer，跳过 `PAGE_EXECUTE_READ` 共享段和 >16MB 大块；
- `main_pairs.py` 只扫根 `Weixin.exe`，不再扫附属子进程；
- 仍复用 10 分钟内的 `mem_model2.json` / `main_pairs.json`。

本机实测：

```text
renderer_scan: ~27s
main_pairs（root-only）: ~25s
```

比原来的 mem_render + seed_scan 两遍 + 全 Weixin 进程明显快，但 UIA 滚轮隔离仍可能限制卡片数量。

## 13.11 同一作者主页里为什么有的 ready、有的 pending

UIA 卡片本身只有：

```text
时长 / 点赞 / 文案 / 封面 / 序号
```

没有 oid、没有 URL。`ready` 不是卡片的属性，而是**本次会话里能不能把它绑到完整流**。

`resolve.py` 的判定：

```text
卡片 seconds
→ by_len[seconds] 找候选
→ 按 index / like 排序
→ 候选 raw_url 必须含 sign + basedata
→ ready
```

pending 的根源按常见程度：

1. **没有该时长的候选**  
   主进程/renderer 里没有这条的 oid/时长记录；通常是因为没 hover、没播放、没预加载、没进过当前批次。

2. **有记录但 URL 不完整**  
   只有 `encfilekey/m/token` 或缓存的短引用，缺 `sign/basedata`，CDN 会 400。

3. **候选时长未知**  
   主进程 meta 的 `vid_len` 经常为空；没有 renderer 记录补时长，就进不了 `by_len`。

4. **oid 已被占用**  
   同一 oid 只能分配给一张卡；重复/截断副本会被排除。

5. **同时长歧义**  
   多条候选的 index/like 都接近，解析器拒绝猜，置 pending。

6. **UIA 只扫到当前加载批次**  
   4.2.0.53 合成滚轮可能被隔离；没扫到的卡不会进列表，已进列表但没绑定记录的仍是 pending。

7. **换号/旧缓存**  
   旧账号的 oid/URL 不能套到新列表；手动重新扫描会强制刷新。

### 已补的 report URL 回退

`decodekey_map.json` 的 `kvReport` 记录常带：

```text
oid + 完整 20302 URL + decodeKey
```

`resolve.py` 现在会在主进程/renderer URL 不完整时，用同 oid 的 report URL 补全。  
本机复测：24 张卡，21 张 ready（此前 12 张卡 11 ready，pending 更多）。

### 怎么让 pending 变 ready

1. 在微信里 hover 该卡 8 秒，或点开播放几秒；
2. 回 viewer 点「重新扫描」；
3. 看 `viewer/work/resolved_cards.json` 的 `note`；
4. 有 seed 但没有 URL 的，仍需先触发一次取流/report 记录。

## 13.12 右键菜单「播放」可用性验证

**2026-11-19 实测**（同一作者主页，12 张可见视频卡）：

```text
12/12 都有：重新进入视频号 / 播放 / 静音播放
```

这些卡片并不都是“原创声明”作品。

**结论**：

- 「播放」不是原创专属；
- 它取决于卡片是否为可播放的视频媒体，以及当前 feed/入口上下文；
- 非原创视频同样能播放；
- 推荐/历史/非视频/不可播卡片可能没有播放项，但这不是“非原创”导致的。

**对右键播放方案的含义**：

- 作者主页的视频卡基本都有「播放」；
- 但仍不能假设所有卡都有，运行时必须检测菜单项；
- 菜单项是 Text，无 InvokePattern，只能坐标点击；
- 点播放会打开播放器，仍是桌面动作，不是 non-hover。

## 14. 目前无法可靠解决的问题

1. **腾讯服务端限流**  
   如果确实存在，客户端只能退避/等待，无法绕过。

2. **URL token 过期**  
   过期后只能重新播放获取新地址；本地缓存 URL 只能短期复用。

3. **微信完全使用本地缓存、不再发请求**  
   没有新 URL 时，只能依赖旧 URL 缓存或内存扫描；两者都不保证成功。

4. **没有内嵌封面且首帧不是微信封面**  
   无法从文件本身恢复“微信当时显示的封面”。

5. **同一条视频多清晰度/多文件头**  
   时长相同，无法只靠时长区分；需要 header MD5。

6. **微信版本升级导致 UIA/内存结构变化**  
   需要重新适配。

7. **标题**  
   已决定不做，不再尝试。

---

## 明天建议的测试顺序

### A. 启动基线

```powershell
# 关闭旧 GUI/HUD/监听后
wscript wx-gui.vbs
```

确认：

```text
GUI 有窗口
8898 正在监听
系统代理 = 127.0.0.1:8898
只有一个 wx-hud
```

### B. Hover 时长实验

选 10 条视频，分别按：

```text
1s / 2s / 3s / 5s
```

停留后点击下载，不要中途清缓存。

### C. 生成报告

```powershell
pwsh -File tools\hover-diag.ps1
```

看：

- 未入库原因；
- `mode=page/player/background`；
- 候选数；
- 首次失败原因；
- 12 秒重试是否恢复。

### D. 失败恢复实验

对失败条目：

1. 等 12 秒看是否自动重试；
2. 重新 hover 同一张卡；
3. 重新播放视频；
4. 记录哪一步恢复。

### E. 限流判定

出现 `hover-cands` 连续为空时：

1. 保持微信前台，等 2–5 分钟；
2. 再 hover 同一张卡；
3. 重启 HUD 再试；
4. 对比 `mode` 与候选数。

如果只有等待才恢复，才考虑腾讯限流。

---

## 回退点

```text
before-range-preflight -> 8522dbb
before-strict-box      -> 530ab4f
```

当前 HEAD：

```text
ecd316a fix: cap preflight scanning and retry a failed URL once
```
