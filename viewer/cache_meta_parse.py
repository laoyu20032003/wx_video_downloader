# -*- coding: utf-8 -*-
"""离线解析 Chromium blockfile 版 Cache_Data 元数据。

覆盖：
  - index v3 IndexHeader / 哈希表；
  - data_0~data_3 BlockFileHeader；
  - EntryStore、RankingsNode、长 key、4 个数据流地址；
  - HTTP 响应头、payload 本地位置和魔数类型；
  - finder.video.qq.com 的 20302/20304/20350 等 query 字段。

仅使用 Python 标准库，不读取微信进程内存。
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import csv
import datetime
import json
import os
import struct
from collections import Counter
from urllib.parse import parse_qsl, unquote, urlparse

ROOT = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(ROOT, "work")
PROFILE_ROOT = os.path.join(
    os.environ["APPDATA"], "Tencent", "xwechat", "radium", "web", "profiles"
)
def _default_profile():
    import glob
    best = None
    for p in glob.glob(os.path.join(PROFILE_ROOT, "*", "Cache", "Cache_Data", "index")):
        try:
            score = max(os.path.getmtime(x) for x in glob.glob(os.path.join(os.path.dirname(p), "f_*")))
        except ValueError:
            score = os.path.getmtime(p)
        if best is None or score > best[0]:
            best = (score, os.path.dirname(os.path.dirname(os.path.dirname(p))))
    return best[1] if best else PROFILE_ROOT
DEFAULT_PROFILE = _default_profile()
INDEX_MAGIC = 0xC103CAC3
BLOCK_MAGIC = 0xC104CAC3
INDEX_VERSION_3 = 0x30000
BLOCK_VERSION_2 = 0x20000
BLOCK_HEADER_SIZE = 8192
UINT32_MASK = 0xFFFFFFFF

ENTRY_STATES = {0: "normal", 1: "evicted", 2: "doomed"}
ADDR_TYPES = {
    0: "separate_file",
    1: "rankings_36",
    2: "block_256",
    3: "block_1024",
    4: "block_4096",
}
# 当前四个 data 文件的 block type 与文件号对应关系。
TYPE_FILE = {1: 0, 2: 1, 3: 2, 4: 3}
STREAM_NAMES = {0: "http_headers", 1: "payload", 2: "stream_2", 3: "stream_3"}


def uint32(value: int) -> int:
    return value & UINT32_MASK


def super_fast_hash(data: bytes) -> int:
    """Chromium base::PersistentHash 使用的 SuperFastHash。"""
    if not data:
        return 0
    hash_value = len(data)
    index = 0
    for _ in range(len(data) // 4):
        hash_value = uint32(hash_value + data[index] + (data[index + 1] << 8))
        tmp = uint32((data[index + 2] + (data[index + 3] << 8)) << 11)
        tmp = uint32(tmp ^ hash_value)
        hash_value = uint32((hash_value << 16) ^ tmp)
        index += 4
        hash_value = uint32(hash_value + (hash_value >> 11))

    remainder = len(data) & 3
    if remainder == 3:
        hash_value = uint32(hash_value + data[index] + (data[index + 1] << 8))
        hash_value = uint32(hash_value ^ (hash_value << 16))
        signed_byte = struct.unpack_from("<b", data, index + 2)[0]
        hash_value = uint32(hash_value ^ uint32(signed_byte << 18))
        hash_value = uint32(hash_value + (hash_value >> 11))
    elif remainder == 2:
        hash_value = uint32(hash_value + data[index] + (data[index + 1] << 8))
        hash_value = uint32(hash_value ^ (hash_value << 11))
        hash_value = uint32(hash_value + (hash_value >> 17))
    elif remainder == 1:
        signed_byte = struct.unpack_from("<b", data, index)[0]
        hash_value = uint32(hash_value + signed_byte)
        hash_value = uint32(hash_value ^ (hash_value << 10))
        hash_value = uint32(hash_value + (hash_value >> 1))

    hash_value = uint32(hash_value ^ (hash_value << 3))
    hash_value = uint32(hash_value + (hash_value >> 5))
    hash_value = uint32(hash_value ^ (hash_value << 4))
    hash_value = uint32(hash_value + (hash_value >> 17))
    hash_value = uint32(hash_value ^ (hash_value << 25))
    hash_value = uint32(hash_value + (hash_value >> 6))
    return hash_value


def decode_cache_addr(addr: int) -> dict:
    if not addr:
        return {"initialized": False, "value": 0, "type": "null"}
    initialized = bool(addr >> 31)
    file_type = (addr >> 28) & 7
    block_count = ((addr >> 24) & 3) + 1
    if file_type == 0:
        return {
            "initialized": initialized,
            "value": addr,
            "type": ADDR_TYPES[0],
            "file_num": addr & ((1 << 28) - 1),
            "block_count": block_count,
        }
    return {
        "initialized": initialized,
        "value": addr,
        "type": ADDR_TYPES.get(file_type, f"unknown_{file_type}"),
        "file_type": file_type,
        "file_selector": (addr >> 16) & 255,
        "block_num": addr & 65535,
        "block_count": block_count,
    }


def detect_magic(head: bytes) -> str:
    if head.startswith(b"\xff\xd8"):
        return "jpeg"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if head.startswith(b"RIFF") and len(head) >= 12 and head[8:12] == b"WEBP":
        return "webp"
    if head.startswith(b"\x1f\x8b"):
        return "gzip"
    if len(head) >= 12 and head[4:8] == b"ftyp":
        return "mp4"
    if head.startswith(b"GIF8"):
        return "gif"
    return "unknown"


def _shared_read_file(path: str) -> bytes:
    """Read a live Chromium cache file without requiring WeChat to close."""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    GENERIC_READ = 0x80000000
    FILE_SHARE_ALL = 0x7
    OPEN_EXISTING = 3
    FILE_ATTRIBUTE_NORMAL = 0x80
    INVALID_HANDLE = wt.HANDLE(-1).value
    h = k32.CreateFileW(str(path), GENERIC_READ, FILE_SHARE_ALL, None,
                        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, None)
    if h == INVALID_HANDLE or not h:
        raise OSError(f"CreateFileW failed: {path}, err={ctypes.get_last_error()}")
    try:
        size = ctypes.c_int64()
        if not k32.GetFileSizeEx(h, ctypes.byref(size)):
            raise OSError("GetFileSizeEx failed")
        buf = (ctypes.c_ubyte * min(max(size.value, 1), 1024 * 1024))()
        got = ctypes.c_ulong()
        out = bytearray()
        while len(out) < size.value:
            want = min(len(buf), size.value - len(out))
            if not k32.ReadFile(h, buf, want, ctypes.byref(got), None):
                raise OSError("ReadFile failed")
            if got.value == 0:
                break
            out.extend(buf[:got.value])
        return bytes(out)
    finally:
        k32.CloseHandle(h)


def snapshot_cache(cache_dir: str, dst_root: str) -> str:
    """Copy only index/data_* to a timestamped snapshot while WeChat runs."""
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    dst = os.path.join(dst_root, ts)
    os.makedirs(dst, exist_ok=False)
    names = ["index"] + [f"data_{i}" for i in range(4)]
    for name in names:
        src = os.path.join(cache_dir, name)
        if not os.path.exists(src):
            continue
        try:
            data = _shared_read_file(src)
        except OSError:
            continue
        with open(os.path.join(dst, name), "wb") as f:
            f.write(data)
    return dst


class BlockfileCache:
    def __init__(self, cache_dir: str, source_dir: str | None = None):
        self.cache_dir = os.path.abspath(cache_dir)
        # snapshot only contains index/data_*; payload f_* are read from the live cache
        self.source_dir = os.path.abspath(source_dir or cache_dir)
        self.index_bytes = self._read_file("index")
        self.index_header, self.lru = self._parse_index_header()
        table_len = self.index_header["table_len"] or 65536
        table_offset = 256 + 112
        if len(self.index_bytes) < table_offset + table_len * 4:
            raise ValueError("index 表长度超过文件实际大小")
        self.table = list(struct.unpack_from(f"<{table_len}I", self.index_bytes, table_offset))

        self.data: dict[int, bytes] = {}
        self.block_headers: dict[int, dict] = {}
        for file_num in range(4):
            data = self._read_file(f"data_{file_num}")
            self.data[file_num] = data
            self.block_headers[file_num] = self._parse_block_header(file_num, data)

    def _read_file(self, name: str) -> bytes:
        path = os.path.join(self.cache_dir, name)
        with open(path, "rb") as f:
            return f.read()

    def _parse_index_header(self) -> tuple[dict, dict]:
        b = self.index_bytes
        if len(b) < 368:
            raise ValueError("index 文件小于 IndexHeader+LruData")
        magic, version = struct.unpack_from("<2I", b, 0)
        if magic != INDEX_MAGIC:
            raise ValueError(f"非法 index magic: 0x{magic:08X}")
        if version != INDEX_VERSION_3:
            raise ValueError(f"仅支持 index v3，当前 0x{version:08X}")
        num_entries, old_v2_num_bytes, last_file, this_id = struct.unpack_from("<4I", b, 8)
        stats, table_len, crash, experiment = struct.unpack_from("<4I", b, 24)
        create_time = struct.unpack_from("<Q", b, 40)[0]
        num_bytes = struct.unpack_from("<q", b, 48)[0]
        corruption_detected = struct.unpack_from("<I", b, 56)[0]
        header = {
            "magic": magic,
            "version": version,
            "num_entries": num_entries,
            "old_v2_num_bytes": old_v2_num_bytes,
            "last_file": last_file,
            "this_id": this_id,
            "stats": stats,
            "table_len": table_len,
            "crash": crash,
            "experiment": experiment,
            "create_time": create_time,
            "num_bytes": num_bytes,
            "corruption_detected": corruption_detected,
        }
        lru_offset = 256
        lru = {
            "pad1": struct.unpack_from("<2I", b, lru_offset),
            "filled": struct.unpack_from("<I", b, lru_offset + 8)[0],
            "sizes": struct.unpack_from("<5I", b, lru_offset + 12),
            "heads": struct.unpack_from("<5I", b, lru_offset + 32),
            "tails": struct.unpack_from("<5I", b, lru_offset + 52),
            "transaction": struct.unpack_from("<I", b, lru_offset + 72)[0],
            "operation": struct.unpack_from("<I", b, lru_offset + 76)[0],
            "operation_list": struct.unpack_from("<I", b, lru_offset + 80)[0],
        }
        return header, lru

    def _parse_block_header(self, file_num: int, data: bytes) -> dict:
        if len(data) < BLOCK_HEADER_SIZE:
            raise ValueError(f"data_{file_num} 小于 BlockFileHeader")
        magic, version = struct.unpack_from("<2I", data, 0)
        if magic != BLOCK_MAGIC:
            raise ValueError(f"非法 data_{file_num} magic: 0x{magic:08X}")
        if version != BLOCK_VERSION_2:
            raise ValueError(f"仅支持 block v2，data_{file_num} 为 0x{version:08X}")
        this_file, next_file = struct.unpack_from("<2h", data, 8)
        entry_size, num_entries, max_entries = struct.unpack_from("<3I", data, 12)
        return {
            "magic": magic,
            "version": version,
            "this_file": this_file,
            "next_file": next_file,
            "entry_size": entry_size,
            "num_entries": num_entries,
            "max_entries": max_entries,
            "empty": struct.unpack_from("<4I", data, 24),
            "hints": struct.unpack_from("<4I", data, 40),
            "updating": struct.unpack_from("<I", data, 56)[0],
            "user": struct.unpack_from("<5I", data, 60),
        }

    def read_addr(self, addr: int, size: int | None = None) -> bytes:
        info = decode_cache_addr(addr)
        if not info["initialized"]:
            raise ValueError("读取了未初始化地址")
        if info["type"] == "separate_file":
            path = os.path.join(self.source_dir, f"f_{info['file_num']:06x}")
            with open(path, "rb") as f:
                return f.read() if size is None else f.read(size)

        file_num = info["file_selector"]
        if file_num not in self.data:
            raise ValueError(f"地址引用了不存在的 data_{file_num}")
        block_size = self.block_headers[file_num]["entry_size"]
        start = BLOCK_HEADER_SIZE + info["block_num"] * block_size
        length = block_size * info["block_count"]
        data = self.data[file_num][start:start + length]
        return data if size is None else data[:size]

    def read_head(self, addr: int, length: int = 32) -> bytes:
        return self.read_addr(addr, length)

    def parse_rankings(self, addr: int, expected_entry: int) -> dict:
        raw = self.read_addr(addr, 36)
        last_used, last_modified = struct.unpack_from("<2Q", raw, 0)
        next_addr, prev_addr, contents, dirty, self_hash = struct.unpack_from("<5I", raw, 16)
        return {
            "addr": f"0x{addr:08X}",
            "last_used": last_used,
            "last_modified": last_modified,
            "next": f"0x{next_addr:08X}",
            "prev": f"0x{prev_addr:08X}",
            "contents": f"0x{contents:08X}",
            "dirty": dirty,
            "self_hash": self_hash,
            "back_reference_ok": contents == expected_entry,
        }

    @staticmethod
    def parse_http_headers(raw: bytes) -> dict:
        start = raw.find(b"HTTP/")
        if start < 0:
            return {"parse_error": "HTTP status not found"}
        segments = []
        pos = start
        while True:
            end = raw.find(b"\0", pos)
            if end < 0:
                break
            segment = raw[pos:end]
            if not segment:
                break
            segments.append(segment.decode("utf-8", "replace"))
            pos = end + 1
        status_line = segments[0] if segments else ""
        headers: dict[str, str] = {}
        header_lines = []
        for line in segments[1:]:
            header_lines.append(line)
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.strip()] = value.strip()
        return {
            "status_line": status_line,
            "response_status": status_line.split(" ", 2)[1] if len(status_line.split()) > 1 else "",
            "headers": headers,
            "header_lines": header_lines,
        }

    @staticmethod
    def parse_url(raw_key: str) -> dict:
        parsed = urlparse(raw_key)
        query = dict(parse_qsl(parsed.query, keep_blank_values=True, errors="replace"))
        path_parts = [x for x in parsed.path.split("/") if x]
        resource_code = path_parts[1] if len(path_parts) >= 2 and path_parts[0].isdigit() else ""
        return {
            "scheme": parsed.scheme,
            "host": parsed.netloc,
            "path": parsed.path,
            "path_parts": path_parts,
            "resource_code": resource_code,
            "query": query,
            "decoded_path": unquote(parsed.path),
        }

    def parse_entry(self, index_slot: int, entry_addr: int) -> dict:
        info = decode_cache_addr(entry_addr)
        if info["type"] != "block_256" or info["file_selector"] != 1:
            raise ValueError(f"index 槽 {index_slot} 未指向 data_1 的 EntryStore")
        entry_raw = self.read_addr(entry_addr)
        hash_value, next_addr, rankings_addr = struct.unpack_from("<3I", entry_raw, 0)
        reuse_count, refetch_count, state = struct.unpack_from("<3I", entry_raw, 12)
        creation_time = struct.unpack_from("<Q", entry_raw, 24)[0]
        key_len, long_key = struct.unpack_from("<2I", entry_raw, 32)
        data_sizes = struct.unpack_from("<4I", entry_raw, 40)
        data_addrs = struct.unpack_from("<4I", entry_raw, 56)
        flags = struct.unpack_from("<I", entry_raw, 72)[0]
        self_hash = struct.unpack_from("<I", entry_raw, 92)[0]

        if long_key:
            raw_key_bytes = self.read_addr(long_key, key_len)
        else:
            raw_key_bytes = entry_raw[96:].split(b"\0", 1)[0]
        if len(raw_key_bytes) != key_len:
            raise ValueError("key_len 与实际 key 长度不一致")
        calculated_hash = super_fast_hash(raw_key_bytes)
        if calculated_hash != hash_value:
            raise ValueError("SuperFastHash 校验失败")
        raw_key = raw_key_bytes.decode("utf-8", "strict")
        if raw_key.startswith("1/0/"):
            url_text = raw_key[4:]
        elif raw_key.startswith("Range_1/0/"):
            url_text = raw_key[len("Range_1/0/"):]
        else:
            raise ValueError("缺少 blockfile key 前缀 1/0/ 或 Range_1/0/")
        url_info = self.parse_url(url_text)

        streams = []
        for stream_index, (stream_size, stream_addr) in enumerate(zip(data_sizes, data_addrs)):
            item = {
                "index": stream_index,
                "name": STREAM_NAMES[stream_index],
                "size": stream_size,
                "addr": f"0x{stream_addr:08X}",
                "addr_info": decode_cache_addr(stream_addr),
            }
            if stream_addr:
                if stream_index == 0:
                    header_raw = self.read_addr(stream_addr, stream_size)
                    item["http"] = self.parse_http_headers(header_raw)
                else:
                    item["magic"] = detect_magic(self.read_head(stream_addr, 32))
                    addr_info = item["addr_info"]
                    if addr_info["type"] == "separate_file":
                        item["local_path"] = os.path.join(
                            self.source_dir,
                            f"f_{addr_info['file_num']:06x}",
                        )
            streams.append(item)

        return {
            "index_slot": index_slot,
            "entry_addr": f"0x{entry_addr:08X}",
            "entry_addr_info": info,
            "hash": hash_value,
            "next_addr": f"0x{next_addr:08X}",
            "rankings": self.parse_rankings(rankings_addr, entry_addr),
            "reuse_count": reuse_count,
            "refetch_count": refetch_count,
            "state": state,
            "state_name": ENTRY_STATES.get(state, f"unknown_{state}"),
            "creation_time": creation_time,
            "key_len": key_len,
            "long_key": f"0x{long_key:08X}",
            "raw_key": raw_key,
            "url": url_text,
            "url_info": url_info,
            "data_sizes": data_sizes,
            "data_addrs": [f"0x{x:08X}" for x in data_addrs],
            "flags": flags,
            "self_hash": self_hash,
            "streams": streams,
        }

    def parse_all(self) -> tuple[list[dict], list[dict]]:
        entries = []
        errors = []
        for slot, addr in enumerate(self.table):
            if not addr:
                continue
            try:
                entries.append(self.parse_entry(slot, addr))
            except Exception as exc:
                errors.append(
                    {
                        "index_slot": slot,
                        "entry_addr": f"0x{addr:08X}",
                        "addr_info": decode_cache_addr(addr),
                        "error": str(exc),
                    }
                )
        return entries, errors


def build_summary(cache: BlockfileCache, entries: list[dict], errors: list[dict]) -> dict:
    headers = Counter()
    payload_magic = Counter()
    resource_codes = Counter()
    hosts = Counter()
    states = Counter()
    for entry in entries:
        hosts[entry["url_info"]["host"]] += 1
        states[entry["state_name"]] += 1
        if entry["url_info"]["resource_code"]:
            resource_codes[entry["url_info"]["resource_code"]] += 1
        for stream in entry["streams"]:
            if stream["name"] == "http_headers" and "http" in stream:
                headers[stream["http"].get("response_status", "")] += 1
            if "magic" in stream:
                payload_magic[stream["magic"]] += 1
    return {
        "cache_dir": cache.cache_dir,
        "index_header": cache.index_header,
        "block_headers": cache.block_headers,
        "lru": cache.lru,
        "counts": {
            "index_nonzero": len(entries) + len(errors),
            "parsed_entries": len(entries),
            "parse_errors": len(errors),
            "hosts": dict(hosts),
            "states": dict(states),
            "resource_codes": dict(resource_codes),
            "http_status": dict(headers),
            "stream_magic": dict(payload_magic),
        },
    }


def write_csv(entries: list[dict], path: str) -> None:
    fields = [
        "index_slot", "entry_addr", "state_name", "host", "resource_code", "url",
        "encfilekey", "token", "m", "uzid", "idx", "picformat", "wxampicformat",
        "http_status", "content_type", "content_length", "x_encflag", "x_enclen",
        "payload_magic", "payload_size", "payload_path",
    ]
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for entry in entries:
            url_info = entry["url_info"]
            query = url_info["query"]
            http_headers = {}
            http_status = ""
            for stream in entry["streams"]:
                if stream["name"] == "http_headers" and "http" in stream:
                    http_status = stream["http"].get("response_status", "")
                    http_headers = stream["http"].get("headers", {})
            payload = next((x for x in entry["streams"] if x["name"] == "payload" and x["addr_info"]["initialized"]), {})
            lower_headers = {k.lower(): v for k, v in http_headers.items()}
            writer.writerow({
                "index_slot": entry["index_slot"],
                "entry_addr": entry["entry_addr"],
                "state_name": entry["state_name"],
                "host": url_info["host"],
                "resource_code": url_info["resource_code"],
                "url": entry["url"],
                "encfilekey": query.get("encfilekey", ""),
                "token": query.get("token", ""),
                "m": query.get("m", ""),
                "uzid": query.get("uzid", ""),
                "idx": query.get("idx", ""),
                "picformat": query.get("picformat", ""),
                "wxampicformat": query.get("wxampicformat", ""),
                "http_status": http_status,
                "content_type": lower_headers.get("content-type", ""),
                "content_length": lower_headers.get("content-length", ""),
                "x_encflag": lower_headers.get("x-encflag", ""),
                "x_enclen": lower_headers.get("x-enclen", ""),
                "payload_magic": payload.get("magic", ""),
                "payload_size": payload.get("size", ""),
                "payload_path": payload.get("local_path", ""),
            })


def atomic_write_json(path: str, obj) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile-dir", default=DEFAULT_PROFILE)
    ap.add_argument("--out-json", default=os.path.join(WORK, "cache_meta_entries.json"))
    ap.add_argument("--summary-json", default=os.path.join(WORK, "cache_meta_summary.json"))
    ap.add_argument("--csv", default=os.path.join(WORK, "cache_meta_entries.csv"))
    ap.add_argument("--errors-json", default=os.path.join(WORK, "cache_meta_errors.json"))
    ap.add_argument("--live", action="store_true",
                    help="snapshot index/data_* while WeChat is running, then parse")
    ap.add_argument("--snapshot-root", default=os.path.join(WORK, "cache_live_snapshot"))
    args = ap.parse_args()

    live_cache = os.path.join(args.profile_dir, "Cache", "Cache_Data")
    source_dir = live_cache
    cache_dir = live_cache
    if args.live:
        cache_dir = snapshot_cache(live_cache, args.snapshot_root)
        source_dir = live_cache
        print("live snapshot:", cache_dir)
    cache = BlockfileCache(cache_dir, source_dir=source_dir)
    entries, errors = cache.parse_all()
    summary = build_summary(cache, entries, errors)

    atomic_write_json(args.out_json, entries)
    atomic_write_json(args.summary_json, summary)
    atomic_write_json(args.errors_json, errors)
    os.makedirs(os.path.dirname(args.csv), exist_ok=True)
    write_csv(entries, args.csv)

    print(json.dumps({
        "parsed": len(entries),
        "errors": len(errors),
        "resource_codes": summary["counts"]["resource_codes"],
        "json": args.out_json,
        "csv": args.csv,
        "summary": args.summary_json,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
