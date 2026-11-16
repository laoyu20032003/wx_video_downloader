# wx-viewer（本项目版本）

独立的视频号卡片列表/封面/下载入口，不依赖 wx-gui。

## 启动

```powershell
wscript wx-viewer.vbs
```

或：

```powershell
pythonw viewer\wx_viewer.py
```

依赖：Python 3.14、comtypes、psutil、Pillow、tkinter、pwsh、ffmpeg/ffprobe。

## 已工作（跨层绑定版）

- UIA 卡片：序号 / 时长 / 点赞 / 文案 / 封面；
- `mem_render.py`：扫描 renderer 堆，得到 `oid / index / vid_len / like / 邻近 20302 URL`；
- `main_pairs.py`：扫描主进程 `oid ↔ 完整签名 URL`；
- `resolve.py`：按 **oid → index → 时长 → 点赞** 对齐，歧义拒绝；
- 表格显示 `ready / pending`；ready 才允许下载；
- 下载：
  ```text
  ready URL
  → UIA 重新定位卡片
  → hover 8 秒（豆包实测：预览解码即可常驻明文头）
  → wx-dl 下载 + 明文头拼接
  ```

实测已成功落盘一条：

```text
视频号_20261117_024143_576p_82s.mp4
10,256,192 bytes
duration 82.33s
```

## 限制

- renderer/主进程记录只覆盖当前会话/已加载卡片；未命中的卡片是 pending；
- hover 8 秒是必要条件，下载前不能刷新页面/切换太远；
- 明文头是有限缓存，新头会挤掉旧头；
- 窗口缩放后仍按 `uia_key` 重新定位，不依赖旧 rect；
- 图片/图文/直播回放不是普通视频。

## 文件

- `wx_viewer.py`：Tkinter UI/扫描/下载编排
- `uia_scan.py`：UIA 卡片读取、滚动、封面、定位、hover
- `main_pairs.py`：主进程 `object_id ↔ URL`
- `mem_render.py`：renderer 堆模型（oid/index/时长/点赞）
- `resolve.py`：跨层绑定解析
- `../wx-viewer.vbs`：无控制台启动器

