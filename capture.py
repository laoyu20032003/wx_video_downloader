# mitmproxy addon：只记录，不改写。
# 记录所有 qq.com 请求到 flows.log，供 wx-dl.ps1 发现视频地址。
from mitmproxy import http
import os, time

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "flows.log")

# 视频类响应不能读 body：一旦访问 flow.response.content，mitmproxy 会把整个视频
# 缓冲进内存（几十 MB 到几百 MB），播放变卡、代理内存翻倍。直接流式透传。
_MEDIA_HOSTS = ("finder.video.qq.com",)
_MEDIA_HINTS = ("stodownload",)


def _is_media(url: str) -> bool:
    if any(h in url for h in _MEDIA_HOSTS):
        return True
    return any(h in url for h in _MEDIA_HINTS)


def response(flow: http.HTTPFlow):
    u = flow.request.pretty_url
    if "qq.com" not in u:
        return

    if _is_media(u):
        flow.response.stream = True     # 只转发，不缓冲
        size = -1                       # 体积未知，留给下载端自己看 Content-Length
        # 封面图 / 头像也走 stodownload，它们不是视频；不记，免得被当成视频去下。
        # 只看响应头，不碰 body。
        ctype = (flow.response.headers.get("content-type") or "").lower()
        if ctype and ("video" not in ctype and "mp4" not in ctype and "octet-stream" not in ctype):
            return
    else:
        try:
            size = len(flow.response.content or b"")
        except Exception:
            size = -1

    try:
        with open(LOG, "a", encoding="utf-8", errors="replace") as f:
            f.write("%s\t%d\t%d\t%s\t%s\n" % (
                time.strftime("%H:%M:%S"), flow.response.status_code, size,
                flow.request.method, u))
    except Exception:
        pass
