# -*- coding: utf-8 -*-
"""三期：跨 renderer 堆聚合卡片模型记录。

枚举所有 `--type=renderer` 的 WeChatAppEx 进程，从堆里抽取三类结构化记录并按 oid 合并：
  1. VNode 卡片串：finder-profile-card,{"feedId":"<oid>";"cols":n;"index":i}  → 网格序号
  2. ele_info："feed_id":"<oid>","session_buffer":"<b64>"               → 解码时长/点赞/位置/scid
  3. 邻近对：<oid>,https://.../20302/stodownload?...                      → 流键/URL
  4. 兼容旧路径：nonceId 后的 base64 recsys blob + 邻近 20302/20304/20350 URL。

落盘 work/mem_model2.json，供 card-resolve 回表补 len/like/index/nonce/URL。
输出记录：{oid, nonce, index, decoded, media:{20302:{...}}, addr}
"""
import ctypes, ctypes.wintypes as wt, re, json, base64, os, sys, argparse, urllib.parse, psutil

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
PROCESS_VM_READ = 0x10
PROCESS_QUERY_INFORMATION = 0x400

class MBI(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", wt.DWORD), ("__a1", wt.DWORD), ("RegionSize", ctypes.c_size_t),
        ("State", wt.DWORD), ("Protect", wt.DWORD), ("Type", wt.DWORD), ("__a2", wt.DWORD)]

NONCE = re.compile(rb"\d{6,}_\d+_\d+_\d+_\d+_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
B64 = re.compile(rb"[A-Za-z0-9+/=]{80,}")
URL_RE = re.compile(rb"https://finder\.video\.qq\.com/251/(\d+)/stodownload\?([^\s\"<\\]*)")
CARD = re.compile(rb'finder-profile-card,\{"feedId":"(\d{16,20})";"cols":(\d+);"index":(\d+)')
ELE = re.compile(rb'"feed_id":"(\d{16,20})","session_buffer":"([A-Za-z0-9+/=]+)"')
PAIR = re.compile(rb'(\d{16,20}),https://finder\.video\.qq\.com/251/\d+/stodownload\?([^\s"\'<>\\;,[\]()]+)')


def regions(h):
    addr = 0; mbi = MBI(); size = ctypes.sizeof(mbi)
    while addr < 0x7FFFFFFFFFFF:
        if not k32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), size):
            break
        if mbi.State == 0x1000 and mbi.Protect in {0x2, 0x4, 0x20, 0x40, 0x8} and mbi.Type != 0x100000:
            yield mbi.BaseAddress or addr, mbi.RegionSize
        addr = (mbi.BaseAddress or addr) + mbi.RegionSize
        if mbi.RegionSize == 0:
            break


def read(h, base, size):
    buf = (ctypes.c_ubyte * size)(); got = ctypes.c_size_t(0)
    if not k32.ReadProcessMemory(h, ctypes.c_void_p(base), buf, size, ctypes.byref(got)):
        return None
    return bytes(buf[:got.value])


def parse_url(qb):
    kv = {}
    for p in qb.split(b"&"):
        if b"=" in p:
            k, v = p.split(b"=", 1)
            kv[k.decode("utf-8", "ignore")] = v.decode("utf-8", "ignore")
    return kv


def decode_b64_json(win):
    b = B64.search(win)
    if not b:
        return None
    try:
        raw = base64.b64decode(b.group(0) + b"=" * (-len(b.group(0)) % 4))
        txt = raw.decode("utf-8", "ignore")
        if "{" not in txt:
            return None
        txt = txt[txt.index("{"):]
        try:
            return json.loads(txt)
        except json.JSONDecodeError:
            cut = txt.rfind("}")
            if cut < 0:
                return None
            return json.loads(txt[:cut + 1])
    except Exception:
        return None


def media_from_url(url_bytes):
    if url_bytes.startswith(b"http"):
        scheme, q = url_bytes.split(b"?", 1)
    else:
        scheme, q = b"https://finder.video.qq.com/251/20302/stodownload", url_bytes
    kv = parse_url(q)
    return {"encfilekey": kv.get("encfilekey", ""), "m": kv.get("m", ""),
            "uzid": kv.get("uzid", ""), "token": kv.get("token", "")[:24],
            "raw_url": (scheme + b"?" + q).decode("utf-8", "ignore")}


def scan_pid(pid, window=3000):
    h = k32.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        return []
    out = {}
    try:
        for base, size in regions(h):
            if size > 64 * 1024 * 1024:
                continue
            data = read(h, base, size)
            if not data:
                continue

            def slot(oid):
                if oid not in out:
                    out[oid] = {"oid": oid, "nonce": None, "index": None,
                                "decoded": None, "media": {}, "addr": hex(base)}
                return out[oid]

            # 1. VNode 卡片序号
            for m in CARD.finditer(data):
                slot(m.group(1).decode())["index"] = int(m.group(3).decode())
            # 2. ele_info session_buffer
            for m in ELE.finditer(data):
                j = decode_b64_json(m.group(2))
                if j:
                    slot(m.group(1).decode())["decoded"] = j
            # 3. oid,URL 邻近对
            for m in PAIR.finditer(data):
                oid = m.group(1).decode()
                rec = slot(oid)
                rec["media"]["20302"] = media_from_url(m.group(2))
            # 4. 旧路径：nonceId + recsys blob + 邻近 URL
            nonces = [(m.start(), m.group(0).decode()) for m in NONCE.finditer(data)]
            for noff, nonce in nonces:
                j = decode_b64_json(data[noff:noff + window])
                oid = str(j.get("object_id")) if j and j.get("object_id") else None
                if oid:
                    rec = slot(oid)
                    rec["nonce"] = nonce
                    if rec["decoded"] is None:
                        rec["decoded"] = j
                else:
                    key = "nonce:" + nonce
                    rec = out.setdefault(key, {"oid": None, "nonce": nonce, "index": None,
                                              "decoded": j, "media": {}, "addr": hex(base + noff)})
                for um in URL_RE.finditer(data[noff:noff + window]):
                    rec["media"][um.group(1).decode()] = media_from_url(um.group(0))
    finally:
        k32.CloseHandle(h)
    return list(out.values())


def renderer_pids():
    out = []
    for p in psutil.process_iter(["pid", "name", "cmdline"]):
        if (p.info["name"] or "").lower() != "wechatappex.exe":
            continue
        cl = " ".join(p.info["cmdline"] or [])
        if "--type=renderer" in cl:
            out.append(p.info["pid"])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                  "work", "mem_model2.json"))
    a = ap.parse_args()

    merged = {}
    total_pid = 0
    for pid in renderer_pids():
        total_pid += 1
        for rec in scan_pid(pid):
            key = rec["oid"] or rec["nonce"]
            old = merged.get(key)
            if old is None:
                merged[key] = rec
            else:
                if old["index"] is None and rec["index"] is not None:
                    old["index"] = rec["index"]
                if old["decoded"] is None and rec["decoded"] is not None:
                    old["decoded"] = rec["decoded"]
                if not old["nonce"] and rec["nonce"]:
                    old["nonce"] = rec["nonce"]
                old.setdefault("media", {}).update(rec.get("media") or {})

    records = list(merged.values())
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(records, open(a.out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    dec = sum(1 for r in records if r["decoded"] and r["decoded"].get("vid_len") is not None)
    idx = sum(1 for r in records if r["index"] is not None)
    print(f"renderer 进程 {total_pid}  记录 {len(records)}  含时长 {dec}  含序号 {idx}")
    for r in sorted(records, key=lambda x: (x["index"] is None, x["index"] or 0))[:15]:
        d = r["decoded"] or {}
        print("-", f"idx={r['index']}", "len=", d.get("vid_len"), "like=", d.get("cur_like_count"),
              "oid=", str(r["oid"])[:16], "nonce=", (r["nonce"] or "")[:18])


if __name__ == "__main__":
    main()
