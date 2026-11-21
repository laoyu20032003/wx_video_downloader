# 安装说明

本文覆盖 Windows 10/11 上的完整安装步骤，重点说明 Python 的 `requests`。

## 1. 先确认版本

已验证环境：

```text
Windows 11
微信 PC 4.2.0.53
PowerShell 7（pwsh）
Python 3.14
mitmproxy 12.2.3
requests 2.32.5
```

## 2. 安装 Python 3.14

从 [python.org](https://www.python.org/downloads/windows/) 下载 Windows 安装包。

安装时勾选：

```text
[✓] Add python.exe to PATH
[✓] py launcher
```

安装后打开新的 PowerShell：

```powershell
py -3.14 --version
python --version
python -m pip --version
```

默认安装路径应为：

```text
C:\Users\<用户名>\AppData\Local\Programs\Python\Python314\
```

`wx-viewer.vbs` 当前按这个路径查找：

```text
%LOCALAPPDATA%\Programs\Python\Python314\pythonw.exe
```

如果你的 Python 不在这个路径：

1. 编辑 `wx-viewer.vbs` 里的 `py = ...`；
2. 或把 Python 安装到上述默认目录。

## 3. 安装 Python 依赖

在项目根目录执行：

```powershell
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

或者手动安装：

```powershell
python -m pip install requests comtypes psutil Pillow mitmproxy
```

### 各依赖用途

| 包 | 用途 |
|---|---|
| `requests` | `viewer/dl_engine.py` 的 HEAD/流式下载，seed 自解密路径必需 |
| `comtypes` | UIA 读取微信视频号卡片 |
| `psutil` | 枚举 `WeChatAppEx.exe` 进程 |
| `Pillow` | 封面缩略图、dHash 校验 |
| `mitmproxy` | `wx-dl`/`wx-gui` 监听模式的 `mitmdump` |
| `tkinter` | Python 自带，viewer 的界面 |

`requests` 是这里最容易漏装的包。

## 4. 单独确认 requests

```powershell
python -c "import requests; print(requests.__version__)"
```

应输出类似：

```text
2.32.5
```

如果报：

```text
ModuleNotFoundError: No module named 'requests'
```

说明当前 `python` 不是安装依赖的那个 Python，或者依赖装到了另一个解释器。

先确认：

```powershell
where python
python -m pip show requests
```

`pip show` 的 `Location` 必须和 `where python` 指向同一套 Python。

### 装错解释器的常见情况

电脑里有 Python 3.12 和 3.14：

```powershell
py -0p
```

给 3.14 安装：

```powershell
py -3.14 -m pip install requests
```

不要只执行：

```powershell
pip install requests
```

因为 `pip` 可能属于另一个 Python。

## 5. pip 网络问题

国内网络可以先换镜像：

```powershell
python -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple requests comtypes psutil Pillow mitmproxy
```

如果仍失败，先升级 pip：

```powershell
python -m pip install --upgrade pip
```

代理环境可以临时指定：

```powershell
python -m pip install --proxy http://127.0.0.1:7890 -r requirements.txt
```

`requests` 在下载引擎里设置了：

```python
s.trust_env = False
```

所以系统代理不会影响视频 HEAD/下载请求。

## 6. 安装 ffmpeg / ffprobe

推荐 winget：

```powershell
winget install Gyan.FFmpeg
```

安装后重开 PowerShell：

```powershell
ffmpeg -version
ffprobe -version
```

也可以从 [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) 下载，把 `bin` 目录加入 PATH。

`ffmpeg`/`ffprobe` 用于：

- 视频结构与时长校验；
- 完整解码校验；
- 可选“下载后加封面帧”。

## 7. 安装 PowerShell 7

`wx-viewer.vbs` 和部分脚本使用 `pwsh`：

```powershell
winget install Microsoft.PowerShell
```

验证：

```powershell
pwsh -NoProfile -Command "$PSVersionTable.PSVersion"
```

Windows 自带 `curl.exe`，无需另装：

```powershell
curl.exe --version
```

## 8. 安装根证书（监听模式）

只有 `wx-dl`/`wx-gui` 的监听模式需要：

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

它只把根证书安装到：

```text
当前用户 → 受信任的根证书颁发机构
```

不需要管理员权限。

`wx-viewer` 不使用代理，不需要这一步。

## 9. 启动前自检

```powershell
python -c "import requests, comtypes, psutil, PIL, tkinter; print('python deps ok')"
mitmdump --version
ffmpeg -version
ffprobe -version
```

然后双击：

```text
wx-viewer.vbs     作者主页卡片列表
wx-gui.vbs        视频库主入口（监听模式）
```

## 10. 常见错误

### `No module named 'requests'`

```powershell
py -3.14 -m pip install requests
```

并确认 `wx-viewer.vbs` 使用的 `pythonw.exe` 就是 3.14。

### `No module named 'comtypes'`

```powershell
python -m pip install comtypes
```

### `No module named 'PIL'`

```powershell
python -m pip install Pillow
```

### `mitmdump` 找不到

```powershell
python -m pip install mitmproxy
where mitmdump
```

如果 `mitmdump.exe` 在：

```text
%LOCALAPPDATA%\Programs\Python\Python314\Scripts\
```

但不在 PATH，把它加入 PATH，或重开终端。

### `ffmpeg` 找不到

确认：

```powershell
where ffmpeg
where ffprobe
```

没有就重新安装 ffmpeg 并加入 PATH。

### viewer 能启动但下载失败

优先检查：

```powershell
python -c "import requests; print(requests.__version__)"
```

因为 seed 自解密路径会直接 import `requests`；缺失时会表现为下载子进程失败，而不是弹窗提示缺少包。

## 11. 依赖清单

仓库根目录的 `requirements.txt` 包含：

```text
requests
comtypes
psutil
Pillow
mitmproxy
```

`tkinter`、`curl.exe` 属于 Windows/Python 自带，不写入 requirements。
