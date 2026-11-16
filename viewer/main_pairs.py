# -*- coding: utf-8 -*-
"""Read-only scanner for Weixin.exe's authoritative object_id <-> stream URL pairs.

Adapted from the Doubao investigation (GPLv3, same project family).
A pair is two adjacent fields in main-process memory:

    19-digit object_id , https://finder.video.qq.com/251/20302/stodownload?...

The scanner also decodes an adjacent base64 recsys blob when possible
(vid_len / like / feed_pos), which is useful for matching a pair to a card.
"""
import base64
import ctypes
import ctypes.wintypes as wt
import json
import re
import urllib.parse

try:
    import psutil
except Exception:
    psutil = None

K32 = ctypes.WinDLL("kernel32", use_last_error=True)
PAIR = re.compile(rb"(\d{16,20})[,\"]\s*(https://finder\.video\.qq\.com/251/(\d+)/stodownload\?[^\s\"'<>\\;,[\]()]+)")
B64 = re.compile(rb"[A-Za-z0-9+/=]{80,}")


class MBI(ctypes.Structure):
    _fields_ = [
        ("BaseAddress", ctypes.c_void_p),
        ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", wt.DWORD),
        ("__a1", wt.DWORD),
        ("RegionSize", ctypes.c_size_t),
        ("State", wt.DWORD),
        ("Protect", wt.DWORD),
        ("Type", wt.DWORD),
        ("__a2", wt.DWORD),
    ]


def regions(h):
    addr = 0
    mbi = MBI()
    size = ctypes.sizeof(mbi)
    while addr < 0x7FFFFFFFFFFF:
        if not K32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), size):
            break
        if mbi.State == 0x1000 and mbi.Protect in {0x2, 0x4, 0x20, 0x40, 0x8} and mbi.Type != 0x100000:
            yield mbi.BaseAddress or addr, mbi.RegionSize
        addr = (mbi.BaseAddress or addr) + mbi.RegionSize
        if mbi.RegionSize == 0:
            break


def read_window(h, addr, span=8000):
    mbi = MBI()
    K32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), ctypes.sizeof(mbi))
    lo = max(mbi.BaseAddress or 0, addr - span)
    hi = min((mbi.BaseAddress or 0) + mbi.RegionSize, addr + span)
    if hi <= lo:
        return b""
    buf = (ctypes.c_ubyte * (hi - lo))()
    got = ctypes.c_size_t(0)
    if not K32.ReadProcessMemory(h, ctypes.c_void_p(lo), buf, hi - lo, ctypes.byref(got)):
        return b""
    return bytes(buf[: got.value])


def decode_meta(win):
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
            d = json.loads(txt)
        except json.JSONDecodeError:
            cut = txt.rfind("}")
            if cut < 0:
                return None
            d = json.loads(txt[: cut + 1])
        return {
            "vid_len": d.get("vid_len"),
            "like": d.get("cur_like_count"),
            "comment": d.get("cur_comment_count"),
            "feed_pos": d.get("feed_pos"),
            "scid": d.get("scid"),
        }
    except Exception:
        return None


def scan_pid(pid):
    h = K32.OpenProcess(0x10 | 0x400, False, pid)
    if not h:
        return {}
    pairs = {}
    try:
        for base, size in regions(h):
            if size > 64 * 1024 * 1024:
                continue
            buf = (ctypes.c_ubyte * size)()
            got = ctypes.c_size_t(0)
            if not K32.ReadProcessMemory(h, ctypes.c_void_p(base), buf, size, ctypes.byref(got)):
                continue
            data = bytes(buf[: got.value])
            for m in PAIR.finditer(data):
                oid = m.group(1).decode()
                kind = m.group(3).decode()
                raw_url = m.group(2).decode("utf-8", "ignore")
                if "?" not in raw_url:
                    continue
                p = urllib.parse.parse_qs(raw_url.split("?", 1)[1])
                key = p.get("encfilekey", [""])[0]
                if not key:
                    continue
                addr = base + m.start()
                e = pairs.get((oid, kind))
                if e is None:
                    e = {
                        "object_id": oid, "kind": kind, "raw_url": raw_url,
                        "encfilekey": key, "m": p.get("m", [""])[0],
                        "token": p.get("token", [""])[0][:24],
                        "uzid": p.get("uzid", [""])[0],
                        "addr": hex(addr), "n": 0, "meta": None,
                    }
                    pairs[(oid, kind)] = e
                else:
                    old_q = urllib.parse.parse_qs(e["raw_url"].split("?", 1)[1])
                    # Keep the most complete signed URL; incomplete references
                    # are rejected by the CDN with 400.
                    if len(p) > len(old_q):
                        e.update(
                            raw_url=raw_url, encfilekey=key,
                            m=p.get("m", [""])[0],
                            token=p.get("token", [""])[0][:24],
                            uzid=p.get("uzid", [""])[0],
                        )
                e["n"] += 1
                if not e["meta"]:
                    e["meta"] = decode_meta(read_window(h, addr))
    finally:
        K32.CloseHandle(h)
    return pairs


def weixin_pids():
    if psutil is None:
        return []
    out = []
    for p in psutil.process_iter(["pid", "name"]):
        if (p.info["name"] or "").lower() == "weixin.exe":
            out.append(p.info["pid"])
    return out


def scan():
    """Scan all Weixin.exe processes, return unique (object_id, kind) rows."""
    best_pid = 0
    best = {}
    for pid in weixin_pids():
        try:
            res = scan_pid(pid)
        except Exception:
            continue
        if len(res) > len(best):
            best_pid, best = pid, res
    rows = sorted(best.values(), key=lambda r: (r["object_id"], r["kind"]))
    # Merge a truncated 18-digit oid into a full 19-digit suffix.
    full = [r for r in rows if len(r["object_id"]) >= 19]
    for r in rows:
        if len(r["object_id"]) >= 19:
            continue
        for f in full:
            if f["object_id"].endswith(r["object_id"]):
                f["n"] += r["n"]
                r["object_id"] = f["object_id"]
                break
    return best_pid, rows


def pair_key(r):
    return (r.get("object_id"), r.get("kind"))


def delta(before, after):
    b = {pair_key(x) for x in before}
    return [x for x in after if pair_key(x) not in b]


if __name__ == "__main__":
    pid, rows = scan()
    print("pid=", pid, "pairs=", len(rows))
    for r in rows:
        m = r.get("meta") or {}
        print(r["object_id"], r["kind"], m.get("vid_len"), m.get("like"),
              r["encfilekey"][:10], "sign=" in r["raw_url"])
