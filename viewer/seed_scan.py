# -*- coding: utf-8 -*-
"""#21：从 renderer V8 堆提取 media.decodeKey，连同同块的 encfilekey/m/token/url 落盘。

oid 不在同一堆窗口，回表靠既有 main_pairs/mem_model2 的 encfilekey→m→token 索引。
用法：python tools/probe-decodekey.py [pid ...]   不带 pid 则扫全部 renderer。
输出：work/decodekey_map.json  [{decodeKey, encfilekey, m, token, urlToken, url, pid, addr}]
"""
import ctypes, ctypes.wintypes as wt, re, json, os, sys, argparse, psutil

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
PROCESS_VM_READ = 0x10
PROCESS_QUERY_INFORMATION = 0x400
ROOT = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(ROOT, "work")

class MBI(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", wt.DWORD), ("__a1", wt.DWORD), ("RegionSize", ctypes.c_size_t),
        ("State", wt.DWORD), ("Protect", wt.DWORD), ("Type", wt.DWORD), ("__a2", wt.DWORD)]

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

DK = re.compile(r'decodeKey"?\s*[:=]\s*"?(\d{6,12})')
ENC = re.compile(r'encfilekey=([^&"\s\\]+)')
MRE = re.compile(r'&m=([0-9a-f]{32})')
TOK = re.compile(r'[?&]token=([^&"\s\\]+)')
URLT = re.compile(r'urlToken"?\s*:\s*"&token=([^&"\s\\]+)')
URL = re.compile(r'https://finder\.video\.qq\.com/251/\d+/stodownload\?[^\s"\\<>]+')
# kvReport 调用串：oid,stodownload URL,decodeKey,14,0,...  —— oid 与 seed 同串直配
REPORT = re.compile(r'(\d{18,20}),https://[^\s,"]+,(\d{6,12}),')

def renderer_pids():
    out = []
    for p in psutil.process_iter(["pid", "name", "cmdline"]):
        if (p.info["name"] or "").lower() != "wechatappex.exe":
            continue
        if "--type=renderer" in " ".join(p.info["cmdline"] or []):
            out.append(p.info["pid"])
    return out

def appex_pids():
    rows = []
    for p in psutil.process_iter(["pid", "name", "memory_info"]):
        if (p.info["name"] or "").lower() != "wechatappex.exe":
            continue
        rss = p.info["memory_info"].rss if p.info["memory_info"] else 0
        rows.append((rss, p.info["pid"]))
    rows.sort(reverse=True)
    return [pid for _, pid in rows[:4]]

def scan_pid(pid):
    h = k32.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        return []
    out = []
    seen = set()
    try:
        for base, size in regions(h):
            if size > 64 * 1024 * 1024:
                continue
            data = read(h, base, size)
            if not data:
                continue
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
                    dk = mk.group(1)
                    enc_m = ENC.search(txt)
                    m_m = MRE.search(txt)
                    tok_m = TOK.search(txt)
                    urlt_m = URLT.search(txt)
                    url_m = URL.search(txt)
                    rec = {
                        "oid": None, "decodeKey": dk,
                        "encfilekey": enc_m.group(1) if enc_m else "",
                        "m": m_m.group(1) if m_m else "",
                        "token": tok_m.group(1) if tok_m else "",
                        "urlToken": urlt_m.group(1) if urlt_m else "",
                        "url": url_m.group(0) if url_m else "",
                        "pid": pid, "addr": hex(base + i), "enc": enc, "src": "blob",
                    }
                    key = (dk, rec["encfilekey"], rec["m"])
                    if key in seen:
                        continue
                    seen.add(key)
                    out.append(rec)
            # kvReport 直配串：oid,URL,decodeKey,...
            for enc, codec in (("u8", "utf-8"), ("u16", "utf-16-le")):
                txt = data.decode(codec, "ignore")
                for rm in REPORT.finditer(txt):
                    oid, dk = rm.group(1), rm.group(2)
                    key = ("rep", oid, dk)
                    if key in seen:
                        continue
                    seen.add(key)
                    out.append({"oid": oid, "decodeKey": dk, "encfilekey": "", "m": "",
                                "token": "", "urlToken": "", "url": "", "pid": pid,
                                "addr": "", "enc": enc, "src": "report"})
    finally:
        k32.CloseHandle(h)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pids", nargs="*", type=int)
    a = ap.parse_args()
    pids = a.pids or appex_pids()
    all_rec = []
    for pid in pids:
        rec = scan_pid(pid)
        print(f"pid {pid}: decodeKey 记录 {len(rec)}")
        all_rec.extend(rec)
    os.makedirs(WORK, exist_ok=True)
    out = os.path.join(WORK, "decodekey_map.json")
    json.dump(all_rec, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("saved", out, len(all_rec))

if __name__ == "__main__":
    main()
