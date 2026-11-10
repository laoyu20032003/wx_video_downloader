# mitmproxy addon：只记录，不改写。
# 记录所有 qq.com 请求到 flows.log，供 wx-dl.ps1 发现视频地址。
from mitmproxy import http
import os, time

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "flows.log")

def response(flow: http.HTTPFlow):
    u = flow.request.pretty_url
    if "qq.com" not in u:
        return
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
