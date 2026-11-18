# -*- coding: utf-8 -*-
"""三期：Python 下载解密引擎（移植 wx-dl.ps1 的 SaveUrl 链路）。

流程：HEAD 取 enclen/total → 下载密文 → 扫 WeChatAppEx 内存明文 MP4 头 →
结构闸门 → ffprobe 时长校验 → ffmpeg 解码校验 → 拼接头+尾落盘。

用法：
  python tools/dl_engine.py --url <url> --tag <tag> --expected-duration <sec>
  成功 stdout 输出 SAVED=<path> exit 0；失败 FAILED exit 2。
"""
import argparse, ctypes, ctypes.wintypes as wt, hashlib, io, os, re, subprocess, sys, datetime, shutil

import psutil
import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from isaac64 import decrypt_prefix

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
PROCESS_QUERY_INFORMATION = 0x400
PROCESS_VM_READ = 0x10

HEADERS = {
    "Referer": "https://liteapp.weixin.qq.com/",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36",
}
FFMPEG_EXTRA = [
    os.path.join(os.environ.get("USERPROFILE", ""), "ffmpeg", "bin"),
    r"C:\Users\ASUS\AppData\Local\Programs\dym\resources\ffmpeg",
]
BENIGN = re.compile(r"non monotonically increasing dts|Application provided invalid")


class MBI(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", wt.DWORD), ("__a1", wt.DWORD), ("RegionSize", ctypes.c_size_t),
        ("State", wt.DWORD), ("Protect", wt.DWORD), ("Type", wt.DWORD), ("__a2", wt.DWORD)]


def resolve_tool(name):
    from shutil import which
    c = which(name)
    if c:
        return c
    for d in FFMPEG_EXTRA:
        p = os.path.join(d, name + ".exe")
        if os.path.exists(p):
            return p
    return None


def run_cmd(cmd, timeout=300):
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="ignore", timeout=timeout)
    return p.returncode, (p.stdout or ""), (p.stderr or "")


def appex_procs():
    out = []
    for pr in psutil.process_iter(["pid", "name", "memory_info"]):
        if (pr.info["name"] or "").lower() == "wechatappex.exe":
            rss = pr.info["memory_info"].rss if pr.info["memory_info"] else 0
            if rss > 60 * 1024 * 1024:
                out.append((pr.info["pid"], rss))
    out.sort(key=lambda x: -x[1])
    return [pid for pid, _ in out]


def _regions(h):
    addr = 0
    mbi = MBI()
    size = ctypes.sizeof(mbi)
    MEM_COMMIT = 0x1000
    MEM_PRIVATE = 0x20000
    PAGE_NOACCESS = 0x1
    PAGE_GUARD = 0x100
    while addr < 0x7FFFFFFFFFFF:
        if not k32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), size):
            break
        if (mbi.State == MEM_COMMIT and mbi.Type == MEM_PRIVATE
                and not (mbi.Protect & PAGE_NOACCESS) and not (mbi.Protect & PAGE_GUARD)
                and mbi.RegionSize <= 64 * 1024 * 1024):
            yield mbi.BaseAddress or addr, mbi.RegionSize
        addr = (mbi.BaseAddress or addr) + mbi.RegionSize
        if mbi.RegionSize == 0:
            break


def _read(h, base, size):
    buf = (ctypes.c_ubyte * size)()
    got = ctypes.c_size_t(0)
    if not k32.ReadProcessMemory(h, ctypes.c_void_p(base), buf, size, ctypes.byref(got)):
        return None
    return bytes(buf[:got.value])


def be32(b, o):
    return ((b[o] << 24) | (b[o+1] << 16) | (b[o+2] << 8) | b[o+3]) & 0xFFFFFFFF


def moov_follows(buf, p):
    for _ in range(4):
        if p + 8 > len(buf):
            return False
        sz = be32(buf, p)
        if sz < 8 or sz > 32 * 1024 * 1024:
            return False
        t = buf[p+4:p+8].decode("ascii", "ignore")
        if t == "moov":
            return True
        if t not in ("free", "wide", "uuid", "skip", "styp", "sidx"):
            return False
        p += sz
    return False


def scan_headers(pid, max_results=20):
    h = k32.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        return []
    found = []
    try:
        for base, size in _regions(h):
            data = _read(h, base, size)
            if not data:
                continue
            for i in range(0, len(data) - 64):
                if data[i+4:i+8] != b"ftyp":
                    continue
                s1 = be32(data, i)
                if s1 < 16 or s1 > 512:
                    continue
                mo = i + s1
                if mo + 8 >= len(data):
                    continue
                if not moov_follows(data, mo):
                    continue
                found.append(base + i)
                if len(found) >= max_results:
                    return found
    finally:
        k32.CloseHandle(h)
    return found


def dump_header(pid, addr, length=131072):
    h = k32.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        return None
    try:
        buf = (ctypes.c_ubyte * length)()
        got = ctypes.c_size_t(0)
        if not k32.ReadProcessMemory(h, ctypes.c_void_p(addr), buf, length, ctypes.byref(got)):
            return None
        return bytes(buf[:got.value])
    finally:
        k32.CloseHandle(h)


def parse_boxes(header):
    pos = 0
    moov_end = 0
    declared = 0
    mdat = False
    first_type = ""
    for _ in range(12):
        if pos + 8 > len(header):
            break
        sz = be32(header, pos)
        t = header[pos+4:pos+8].decode("ascii", "ignore")
        if sz == 1:
            if pos + 16 > len(header):
                break
            sz = be32(header, pos+8) * 4294967296 + be32(header, pos+12)
        elif sz == 0:
            sz = None
        if pos == 0:
            first_type = t
        if t == "moov":
            moov_end = pos + sz
        if sz is None or sz <= 0:
            break
        declared = pos + sz
        pos += sz
        if t == "mdat":
            mdat = True
            break
    return {"moov_end": moov_end, "declared": declared, "mdat": mdat, "first_type": first_type}


def read_plain(cipher, off, n):
    try:
        with open(cipher, "rb") as f:
            f.seek(off)
            b = f.read(n)
        return b if len(b) == n else None
    except Exception:
        return None


def bytes_at(header, cipher, enclen, pos, n):
    if pos + n <= len(header):
        return header[pos:pos+n]
    if pos >= enclen:
        return read_plain(cipher, pos, n)
    return None


def layout_gate(header, cipher, enclen):
    size = os.path.getsize(cipher)
    pos = 0
    declared_end = 0
    first_type = ""
    moov = mdat = False
    guard = 0
    while pos < size and guard < 64:
        guard += 1
        hb = bytes_at(header, cipher, enclen, pos, 8)
        if not hb:
            break
        sz = be32(hb, 0)
        t = hb[4:8].decode("ascii", "ignore")
        if sz == 1:
            hb16 = bytes_at(header, cipher, enclen, pos, 16)
            if not hb16:
                break
            sz = be32(hb16, 8) * 4294967296 + be32(hb16, 12)
        elif sz == 0:
            sz = size - pos
        if pos == 0:
            first_type = t
        if t == "moov":
            moov = True
            if pos + sz > size:
                return False, f"moov 声明 {sz} 字节，比整个文件（{size}）还大", 0
        if sz <= 0:
            break
        declared_end = pos + sz
        pos += sz
        if t == "mdat":
            mdat = True
            break
    if first_type != "ftyp":
        return False, f"头不是以 ftyp 开头（读到 '{first_type}'）", 0
    if not moov:
        return False, "头里没有 moov", 0
    if not mdat:
        return False, "头里没有 mdat", 0
    if declared_end <= 0:
        return False, "box 结构读不出来", 0
    diff = declared_end - size
    tol = max(1024, int(size * 0.0002))
    if abs(diff) > tol:
        return False, f"头声明总长 {declared_end}，密文 {size}，差 {diff}（别的视频的头）", 0
    return True, "", declared_end


def gate_plain(path):
    """自解密后的整文件结构闸门：头里必须有 ftyp/moov/mdat。"""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        head = f.read(min(2 * 1024 * 1024, size))
    info = parse_boxes(head)
    if info["first_type"] != "ftyp":
        return False, f"头不是以 ftyp 开头（读到 '{info['first_type']}'）"
    if not info["moov_end"]:
        return False, "头里没有 moov"
    if not info["mdat"]:
        return False, "头里没有 mdat"
    return True, ""


def probe_duration(probe, path):
    try:
        rc, out, _ = run_cmd([probe, "-v", "error", "-show_entries", "format=duration",
                              "-of", "default=nw=1:nk=1", path])
        v = (out or "").strip()
        return float(v) if v else 0.0
    except Exception:
        return 0.0


def real_decode_errors(err_text):
    n = 0
    for line in (err_text or "").splitlines():
        line = line.strip()
        if line and not BENIGN.search(line):
            n += 1
    return n


def decode_check(ffmpeg, path, t=None):
    cmd = [ffmpeg, "-v", "error", "-i", path]
    if t:
        cmd += ["-t", str(t)]
    cmd += ["-f", "null", "-"]
    try:
        rc, _, err = run_cmd(cmd, timeout=600 if t is None else 120)
    except Exception:
        return False, 1
    if rc != 0:
        return False, 1
    return real_decode_errors(err) == 0, real_decode_errors(err)


def http_head(url):
    s = requests.Session()
    s.trust_env = False
    r = s.head(url, headers=HEADERS, timeout=10, allow_redirects=True)
    enclen = r.headers.get("X-enclen")
    enclen = int(enclen) if enclen and enclen.isdigit() else 131072
    total = r.headers.get("Content-Length")
    total = int(total) if total and total.isdigit() else 0
    return r.status_code, enclen, total


def download_cipher(url, cipher_path):
    s = requests.Session()
    s.trust_env = False
    with s.get(url, headers=HEADERS, stream=True, timeout=900) as r:
        if r.status_code != 200:
            return r.status_code, 0
        with open(cipher_path, "wb") as f:
            for chunk in r.iter_content(1024 * 1024):
                if chunk:
                    f.write(chunk)
    return 200, os.path.getsize(cipher_path)


def _cleanup(*paths):
    for f in paths:
        try:
            if f and os.path.exists(f):
                os.remove(f)
        except Exception:
            pass


def concat_save(header, cipher_path, enclen, out_path):
    with open(out_path, "wb") as out:
        out.write(header)
        with open(cipher_path, "rb") as src:
            src.seek(enclen)
            while True:
                b = src.read(1024 * 1024)
                if not b:
                    break
                out.write(b)


def _save_final(ffmpeg, ffprobe, candidate, expected_duration, out_dir, tag):
    """结构/时长/解码校验通过后命名落盘，返回 out_path 或 None。"""
    dur = probe_duration(ffprobe, candidate)
    if not dur or dur <= 1:
        return None
    if expected_duration > 0 and abs(dur - expected_duration) > 3:
        print(f"跳过：时长 {dur:.1f}s 与卡片 {expected_duration}s 不符")
        return None
    ok3, _ = decode_check(ffmpeg, candidate, t=3)
    if not ok3:
        return None
    full_ok, _ = decode_check(ffmpeg, candidate)
    if not full_ok:
        return None
    whinfo = subprocess.run([ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "csv=p=0", candidate],
        capture_output=True, text=True, encoding="utf-8", errors="ignore").stdout.strip()
    wh = whinfo.split(",")
    h = min(int(wh[0]), int(wh[1])) if len(wh) >= 2 and wh[0].isdigit() else "?"
    name = f"视频号_{datetime.datetime.now():%Y%m%d_%H%M%S}_{h}p_{round(dur)}s.mp4"
    out_path = os.path.join(out_dir, name)
    shutil.move(candidate, out_path)
    print(f"已保存: {out_path}")
    return out_path


def fix_decrypt(url, tag, expected_duration, work_dir, out_dir, enclen, seed_int):
    """seed(decodeKey) ISAAC64 自解密分支：不依赖内存明文头。"""
    ffmpeg = resolve_tool("ffmpeg")
    ffprobe = resolve_tool("ffprobe")
    if not ffmpeg or not ffprobe:
        print("找不到 ffmpeg/ffprobe")
        return None

    os.makedirs(work_dir, exist_ok=True)
    cipher = os.path.join(work_dir, f"cipher_{tag}.bin")
    candidate = os.path.join(work_dir, f"cand_{tag}.mp4")

    code, clen = download_cipher(url, cipher)
    if code != 200:
        print("下载失败 HTTP=%d" % code)
        _cleanup(cipher)
        return None
    if clen <= enclen:
        print(f"文件过短（{clen} 字节）")
        _cleanup(cipher)
        return None

    with open(cipher, "rb") as f:
        raw = f.read()
    plain = decrypt_prefix(raw, seed_int, enclen)
    with open(candidate, "wb") as f:
        f.write(plain)

    ok, reason = gate_plain(candidate)
    if not ok:
        print(f"自解密结构闸门未过：{reason}（seed={seed_int} 可能不匹配本条）")
        _cleanup(cipher, candidate)
        return None

    out = _save_final(ffmpeg, ffprobe, candidate, expected_duration, out_dir, tag)
    _cleanup(cipher)
    if not out:
        _cleanup(candidate)
    return out


def fix(url, tag, expected_duration, work_dir, out_dir, seed=None):
    # 内存字符串可能混入 NUL/控制字符，先清掉，避免下游请求/命令报错
    url = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", url)
    ffmpeg = resolve_tool("ffmpeg")
    ffprobe = resolve_tool("ffprobe")
    if not ffmpeg or not ffprobe:
        print("找不到 ffmpeg/ffprobe")
        return None

    code, enclen, total = http_head(url)
    if code in (403, 401):
        print("地址已过期（HTTP %d），请重新悬停" % code)
        return None
    if code not in (200, 206):
        print("HEAD 失败 HTTP=%d" % code)
        return None
    if enclen < 1024 or enclen > 4194304:
        enclen = 131072

    seed_int = None
    if seed:
        try:
            seed_int = int(str(seed).strip())
        except (TypeError, ValueError):
            seed_int = None
    if seed_int is not None:
        return fix_decrypt(url, tag, expected_duration, work_dir, out_dir, enclen, seed_int)

    procs = appex_procs()
    if not procs:
        print("没有 WeChatAppEx 进程，请先打开视频号")
        _cleanup(None, None)
        return None

    # 预扫常驻明文 MP4 头并缓存，避免下完整密文后才发现内存里没有配对头
    resident = []
    for pid in procs:
        for addr in scan_headers(pid, 20):
            header = dump_header(pid, addr, enclen)
            if not header or len(header) < 4096:
                continue
            info = parse_boxes(header)
            resident.append((pid, addr, header, info))

    # 早筛：HEAD 拿到的整文件大小，与任一常驻头声明长度比对；对不上就不必下载密文
    if total > 0:
        tol = max(1024, int(total * 0.0002))
        hit = [i for _, _, _, i in resident if i["mdat"] and abs(i["declared"] - total) <= tol]
        if not hit:
            print(f"内存无对应明文头（常驻 {len(resident)} 个，大小均与地址 {total} 不符）："
                  "请在微信里播放/悬停该视频几秒后重试")
            _cleanup(None, None)
            return None

    os.makedirs(work_dir, exist_ok=True)
    cipher = os.path.join(work_dir, f"cipher_{tag}.bin")
    candidate = os.path.join(work_dir, f"cand_{tag}.mp4")

    code, clen = download_cipher(url, cipher)
    if code != 200:
        print("下载失败 HTTP=%d" % code)
        _cleanup(cipher)
        return None
    if clen <= enclen:
        print(f"文件过短（{clen} 字节）")
        _cleanup(cipher)
        return None

    seen = {}
    for pid, addr, header, info in resident:
        key = hashlib.md5(header).hexdigest()
        if key in seen:
            continue
        seen[key] = 1

        ok, reason, _ = layout_gate(header, cipher, enclen)
        if not ok:
            print(f"跳过候选 pid={pid} 0x{addr:X}：{reason}")
            continue

        concat_save(header, cipher, enclen, candidate)
        dur = probe_duration(ffprobe, candidate)
        if not dur or dur <= 1:
            continue
        if expected_duration > 0 and abs(dur - expected_duration) > 3:
            print(f"跳过候选：时长 {dur:.1f}s 与卡片 {expected_duration}s 不符")
            continue

        ok3, _ = decode_check(ffmpeg, candidate, t=3)
        if not ok3:
            continue
        full_ok, _ = decode_check(ffmpeg, candidate)
        if not full_ok:
            continue

        whinfo = subprocess.run([ffprobe, "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-of", "csv=p=0", candidate],
            capture_output=True, text=True, encoding="utf-8", errors="ignore").stdout.strip()
        wh = whinfo.split(",")
        h = min(int(wh[0]), int(wh[1])) if len(wh) >= 2 and wh[0].isdigit() else "?"
        name = f"视频号_{datetime.datetime.now():%Y%m%d_%H%M%S}_{h}p_{round(dur)}s.mp4"
        out_path = os.path.join(out_dir, name)
        shutil.move(candidate, out_path)
        _cleanup(cipher)
        print(f"已保存: {out_path}")
        return out_path

    if not seen:
        print("内存里没有候选明文头：请把这条视频重新播放几秒再来")
    else:
        print(f"{len(seen)} 个候选头都未通过校验，请重播后重试")
    _cleanup(cipher, candidate)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--tag", default="manual")
    ap.add_argument("--expected-duration", type=int, default=0)
    ap.add_argument("--seed", default="", help="decodeKey 十进制串，提供则走 ISAAC64 自解密分支")
    ap.add_argument("--work", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "work"))
    ap.add_argument("--outdir", default=os.path.join(os.environ.get("USERPROFILE", ""), "Documents", "视频号"))
    a = ap.parse_args()

    tag = re.sub(r"[^0-9A-Za-z_-]", "", a.tag) or "manual"
    saved = fix(a.url, tag, a.expected_duration, a.work, a.outdir, seed=a.seed)
    if saved:
        print(f"SAVED={saved}")
        sys.exit(0)
    print("FAILED")
    sys.exit(2)


if __name__ == "__main__":
    main()
