# wx-viewer（本项目版本）

独立的视频号卡片列表/封面/下载入口，不依赖 `wx-gui`、mitmproxy 或 HUD。

![wx-viewer](../images/wx-viewer.png)

## 启动

```powershell
wscript wx-viewer.vbs
```

或：

```powershell
pythonw viewer\wx_viewer.py
```

依赖：Python 3.14、comtypes、psutil、Pillow、tkinter、pwsh、curl、ffmpeg/ffprobe。

## 功能

- UIA 卡片：序号 / 时长 / 点赞 / 文案 / 封面 / 状态；
- 每行有「下载」操作；
- 切换视频号账号/作者主页后点「重新扫描」：清空旧列表、强制重扫 renderer/主进程，避免旧账号的 oid/URL 串到新列表；
- `ready` 行：hover 8 秒取明文头后下载；
- `pending` 行：点击后自动 hover 8 秒，重扫 renderer/主进程，按 oid/index/时长/点赞重新绑定，成功后再下载；
- 扫描时左上角显示「视频号扫描」进度窗；主窗口暂时隐藏，避免遮住封面；
- 10 分钟内的 renderer/主进程结果会复用，避免每次重扫。

## 跨层绑定

- `mem_render.py`：renderer 堆里的 `oid / index / vid_len / like / 邻近 20302 URL`；
- `main_pairs.py`：主进程 `oid ↔ 完整签名 URL`；
- `resolve.py`：按 **oid → index → 时长 → 点赞** 对齐，歧义拒绝；
- 只有含 `sign + basedata` 的 URL 才进入 `ready`。

## 下载

```text
ready/pending
→ UIA 重新定位卡片
→ hover 8 秒（预览解码，明文头常驻；不必点开播放器）
→ 匹配 oid / 完整 URL
→ wx-dl 下载密文 + 拼接明文头 + 全片校验
```

实测成功样例：

```text
视频号_20261117_024143_576p_82s.mp4
10,256,192 bytes
duration 82.33s
```

## 限制

- renderer/主进程记录只覆盖当前会话/已加载卡片；未命中的卡片是 pending；
- hover 8 秒是必要条件，下载前不能刷新页面/切换太远；
- 明文头是有限缓存，新头会挤掉旧头；
- 同一时间只允许一个下载任务（hover/滚轮/明文头都是全局状态）；
- 窗口缩放后按 `uia_key` 重新定位，不依赖旧 rect；
- 图片/图文/直播回放不是普通视频。

## 排查

日志：

```text
viewer/work/viewer.log
viewer/work/resolved_cards.json
viewer/work/main_pairs.json
viewer/work/mem_model2.json
```

扫描阶段和 pending 处理的常见问题见
[docs/known-issues.md](../docs/known-issues.md)。

## 文件

- `wx_viewer.py`：Tkinter UI/扫描/下载编排
- `uia_scan.py`：UIA 卡片读取、滚动、封面、定位、hover
- `main_pairs.py`：主进程 `object_id ↔ URL`
- `mem_render.py`：renderer 堆模型（oid/index/时长/点赞）
- `resolve.py`：跨层绑定解析
- `../wx-viewer.vbs`：无控制台启动器

