# -*- coding: utf-8 -*-
"""合并 renderer 堆扫描：一次内存读取，同时抽取卡片模型记录与 decodeKey/seed 映射。

合并自 mem-render.py（卡片模型 → mem_model2.json）与 probe-decodekey.py（seed → decodekey_map.json）。
原先两个脚本各把同一批 renderer 的内存区域读一遍，合并后只读一遍，read 开销减半。

输出：
  work/mem_model2.json      [{oid, nonce, index, decoded, media, addr}]
  work/decodekey_map.json   [{oid, decodeKey, encfilekey, m, token, urlToken, url, pid, addr, enc, src}]
"""
import ctypes, ctypes.wintypes as wt, re, json, base64, os, argparse, urllib.parse, psutil

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
PROCESS_VM_READ = 0x10
PROCESS_QUERY_INFORMATION = 0x400
ROOT = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(ROOT, "work")


class MBI(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", wt.DWORD), ("__a1", wt.DWORD), ("RegionSize", ctypes.c_size_t),
        ("State", wt.DWORD), ("Protect", wt.DWORD), ("Type", wt.DWORD), ("__a2", wt.DWORD)]


# ---------- 卡片模型正则（mem-render） ----------
NONCE = re.compile(rb"\d{6,}_\d+_\d+_\d+_\d+_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
B64 = re.compile(rb"[A-Za-z0-9+/=]{80,}")
URL_RE = re.compile(rb"https://finder\.video\.qq\.com/251/(\d+)/stodownload\?([^\s\"<\\]*)")
CARD = re.compile(rb'finder-profile-card,\{"feedId":"(\d{16,20})";"cols":(\d+);"index":(\d+)')
ELE = re.compile(rb'"feed_id":"(\d{16,20})","session_buffer":"([A-Za-z0-9+/=]+)"')
PAIR = re.compile(rb'(\d{16,20}),https://finder\.video\.qq\.com/251/\d+/stodownload\?([^\s"\'<>\\;,[\]()]+)')

# ---------- decodeKey / seed 正则（probe-decodekey） ----------
DK = re.compile(r'decodeKey"?\s*[:=]\s*"?(\d{6,12})')
ENC = re.compile(r'encfilekey=([^&"\s\\]+)')
MRE = re.compile(r'&m=([0-9a-f]{32})')
TOK = re.compile(r'[?&]token=([^&"\s\\]+)')
URLT = re.compile(r'urlToken"?\s*:\s*"&token=([^&"\s\\]+)')
URL = re.compile(r'https://finder\.video\.qq\.com/251/\d+/stodownload\?[^\s"\\<>]+')
REPORT = re.compile(r'(\d{18,20}),(https://[^\s,"]+),(\d{6,12}),')

# 块级预筛关键字：mem + dk 合并
NEEDLES = (b"finder-profile-card", b"feed_id", b"stodownload", b"feedId",
           b"session_buffer", b"object_id", b"decodeKey")


def regions(h):
    addr = 0; mbi = MBI(); size = ctypes.sizeof(mbi)
    while addr < 0x7FFFFFFFFFFF:
        if not k32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), size):
            break
        # 0x20 EXEC_READ 共享代码段（每进程固定 ~267MB），目标串不在其中，排除
        if mbi.State == 0x1000 and mbi.Protect in {0x2, 0x4, 0x40, 0x8} and mbi.Type != 0x100000:
            yield mbi.BaseAddress or addr, mbi.RegionSize
        addr = (mbi.BaseAddress or addr) + mbi.RegionSize
        if mbi.RegionSize == 0:
            break


def read(h, base, size):
    buf = (ctypes.c_ubyte * size)(); got = ctypes.c_size_t(0)
    if not k32.ReadProcessMemory(h, ctypes.c_void_p(base), buf, size, ctypes.byref(got)):
        return None
    return bytes(buf[:got.value])


def _weixin_chain(pid):
    seen = set()
    while pid and pid not in seen:
        seen.add(pid)
        try:
            p = psutil.Process(pid)
        except Exception:
            return False
        if (p.name() or "").lower() == "weixin.exe":
            return True
        pid = p.ppid()
    return False


def _rw_bytes(pid):
    """统计进程 READWRITE 堆字节，用于区分当前活动 webview 与历史残留空 renderer。"""
    h = k32.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        return 0
    total = 0
    try:
        addr = 0; mbi = MBI(); size = ctypes.sizeof(mbi)
        while addr < 0x7FFFFFFFFFFF:
            if not k32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), size):
                break
            if mbi.State == 0x1000 and mbi.Type != 0x100000 and mbi.Protect == 0x4:
                total += mbi.RegionSize
            addr = (mbi.BaseAddress or addr) + mbi.RegionSize
            if mbi.RegionSize == 0:
                break
    finally:
        k32.CloseHandle(h)
    return total


def renderer_pids(min_rw=60 * 1024 * 1024):
    out = []
    for p in psutil.process_iter(["pid", "name", "cmdline"]):
        if (p.info["name"] or "").lower() != "wechatappex.exe":
            continue
        cl = " ".join(p.info["cmdline"] or [])
        if "--type=renderer" not in cl or "preload" in cl:
            continue
        if not _weixin_chain(p.info["pid"]):
            continue
        if _rw_bytes(p.info["pid"]) < min_rw:  # 历史残留空 renderer，无当前账号数据
            continue
        out.append(p.info["pid"])
    return out


# ---------- mem 辅助 ----------
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
        return {}, []
    mem = {}
    dk = []
    seen = set()
    try:
        for base, size in regions(h):
            # 结构化卡片/seed 对象落在小 V8 块；>16MB 大块是位图/媒体缓存与共享固定段，跳过
            if size > 16 * 1024 * 1024:
                continue
            data = read(h, base, size)
            if not data:
                continue
            if not any(n in data for n in NEEDLES):
                continue

            # ---- 卡片模型 ----
            def slot(oid):
                if oid not in mem:
                    mem[oid] = {"oid": oid, "nonce": None, "index": None,
                                "decoded": None, "media": {}, "addr": hex(base)}
                return mem[oid]

            for m in CARD.finditer(data):
                slot(m.group(1).decode())["index"] = int(m.group(3).decode())
            for m in ELE.finditer(data):
                j = decode_b64_json(m.group(2))
                if j:
                    slot(m.group(1).decode())["decoded"] = j
            for m in PAIR.finditer(data):
                slot(m.group(1).decode())["media"]["20302"] = media_from_url(m.group(2))
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
                    rec = mem.setdefault(key, {"oid": None, "nonce": nonce, "index": None,
                                              "decoded": j, "media": {}, "addr": hex(base + noff)})
                for um in URL_RE.finditer(data[noff:noff + window]):
                    rec["media"][um.group(1).decode()] = media_from_url(um.group(0))

            # ---- decodeKey / seed ----
            for enc, needle, codec in (("u8", b"decodeKey", "utf-8"),
                                        ("u16", "decodeKey".encode("utf-16-le"), "utf-16-le")):
                start = 0
                while True:
                    i = data.find(needle, start)
                    if i < 0:
                        break
                    start = i + len(needle)
                    win = data[max(0, i - 800): i + 800]
                    txt = win.decode(codec, "ignore")
                    mk = DK.search(txt)
                    if not mk:
                        continue
                    dkval = mk.group(1)
                    enc_m = ENC.search(txt); m_m = MRE.search(txt)
                    tok_m = TOK.search(txt); urlt_m = URLT.search(txt); url_m = URL.search(txt)
                    rec = {"oid": None, "decodeKey": dkval,
                        "encfilekey": enc_m.group(1) if enc_m else "",
                        "m": m_m.group(1) if m_m else "",
                        "token": tok_m.group(1) if tok_m else "",
                        "urlToken": urlt_m.group(1) if urlt_m else "",
                        "url": url_m.group(0) if url_m else "",
                        "pid": pid, "addr": hex(base + i), "enc": enc, "src": "blob"}
                    key = (dkval, rec["encfilekey"], rec["m"])
                    if key in seen:
                        continue
                    seen.add(key)
                    dk.append(rec)
            for enc, codec in (("u8", "utf-8"), ("u16", "utf-16-le")):
                txt = data.decode(codec, "ignore")
                for rm in REPORT.finditer(txt):
                    oid, rep_url, dkval = rm.group(1), rm.group(2), rm.group(3)
                    key = ("rep", oid, dkval)
                    if key in seen:
                        continue
                    seen.add(key)
                    dk.append({"oid": oid, "decodeKey": dkval, "encfilekey": "", "m": "",
                                "token": "", "urlToken": "", "url": rep_url, "pid": pid,
                                "addr": "", "enc": enc, "src": "report"})
    finally:
        k32.CloseHandle(h)
    return mem, dk


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mem-out", default=os.path.join(WORK, "mem_model2.json"))
    ap.add_argument("--dk-out", default=os.path.join(WORK, "decodekey_map.json"))
    a = ap.parse_args()

    merged = {}
    all_dk = []
    total_pid = 0
    for pid in renderer_pids():
        total_pid += 1
        mem, dk = scan_pid(pid)
        print(f"pid {pid}: 卡片 {len(mem)}  seed {len(dk)}")
        for rec in mem.values():
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
        all_dk.extend(dk)

    mem_records = list(merged.values())
    os.makedirs(WORK, exist_ok=True)
    json.dump(mem_records, open(a.mem_out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    json.dump(all_dk, open(a.dk_out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    dec = sum(1 for r in mem_records if r["decoded"] and r["decoded"].get("vid_len") is not None)
    idx = sum(1 for r in mem_records if r["index"] is not None)
    rep = sum(1 for r in all_dk if r.get("src") == "report")
    print(f"renderer 进程 {total_pid}  卡片记录 {len(mem_records)}  含时长 {dec}  含序号 {idx}  "
          f"seed {len(all_dk)} (report {rep})")


if __name__ == "__main__":
    main()
