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

## 当前已工作

- UIA 从顶部顺序翻页采集作者主页卡片；
- 不按 163 截断，采到连续两页无新增；
- 每张卡显示封面、时长、点赞、文案、状态；
- 封面来自卡片可见时的屏幕截图，保存到 `viewer/work/covers_uia/`；
- 扫描时 viewer 自动隐藏，避免遮住微信卡片；
- 点击「下载选中」时：
  1. 按 `duration|like|desc` 重新在当前 UIA 网格定位卡片；
  2. 滚动到可见；
  3. 先 hover，拿不到再 UIA Invoke；
  4. 扫描主进程新增 `object_id ↔ 完整 URL`；
  5. 唯一且时长匹配才交给 `wx-dl.ps1` 下载。

## 当前未完成/限制

- 扫描数量会浮动（实测 321 / 330 / 539），说明仍有虚拟列表/历史节点；
- 主进程字节扫描较慢，激活后要等几秒；
- hover 可能只预取加密流，没有明文头时 `wx-dl` 仍会失败；
- 没有拿到 `object_id` 的卡片只能是 `pending`，不猜；
- 封面是屏幕截图，不是原图；viewer 与微信不能重叠；
- 图片动态/图文/直播回放不是普通视频，下载前应跳过；
- 固定 slot 的全量顺序仍需按 `object_id` 校正。

## 文件

- `wx_viewer.py`：Tkinter UI/扫描/激活/下载编排
- `uia_scan.py`：UIA 卡片读取、滚动、封面、定位、hover/Invoke
- `main_pairs.py`：Weixin.exe 主进程 `object_id ↔ URL` 扫描
- `../wx-viewer.vbs`：无控制台启动器
