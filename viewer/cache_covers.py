# -*- coding: utf-8 -*-
"""CEF cache cover provider.

Online: f_* files are JPEG response bodies; sort by mtime, SHA-256 dedupe,
copy to viewer/work/cache_covers/idx_*.jpg.

Offline: viewer/cache_meta_parse.py can produce cache_meta_entries.csv;
this module maps payload_path (f_*) -> cover URL / encfilekey / m.
"""
from __future__ import annotations

import csv
import glob
import hashlib
import json
import os
import shutil
from datetime import datetime

APPDATA = os.environ.get("APPDATA") or os.path.expanduser("~")
PROFILE_ROOT = os.path.join(APPDATA, "Tencent", "xwechat", "radium", "web", "profiles")
WORK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work")
COVER_DIR = os.path.join(WORK, "cache_covers")
META_CSV = os.path.join(WORK, "cache_meta_entries.csv")
MAP_PATH = os.path.join(WORK, "cache_cover_map.json")


def load_map():
    try:
        with open(MAP_PATH, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_map(d):
    try:
        os.makedirs(WORK, exist_ok=True)
        with open(MAP_PATH, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=1)
    except Exception:
        pass


def _cache_dirs():
    rows = []
    for p in glob.glob(os.path.join(PROFILE_ROOT, "*", "Cache", "Cache_Data")):
        try:
            fs = [x for x in glob.glob(os.path.join(p, "f_*")) if os.path.isfile(x)]
            if not fs:
                continue
            latest = max(os.path.getmtime(x) for x in fs)
            rows.append((latest, len(fs), p))
        except OSError:
            continue
    rows.sort(reverse=True)
    return rows


def _jpeg_sha(path):
    try:
        with open(path, "rb") as f:
            if f.read(2) != b"\xff\xd8":
                return None
            f.seek(0)
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def load_url_map():
    """Map basename(f_*) -> metadata row from offline cache parse."""
    out = {}
    if not os.path.exists(META_CSV):
        return out
    try:
        with open(META_CSV, encoding="utf-8-sig", newline="") as f:
            for row in csv.DictReader(f):
                path = (row.get("payload_path") or "").strip()
                if not path:
                    continue
                name = os.path.basename(path)
                url = (row.get("url") or "").strip()
                if not url:
                    continue
                out[name] = {
                    "url": url,
                    "resource_code": row.get("resource_code") or "",
                    "encfilekey": row.get("encfilekey") or "",
                    "m": row.get("m") or "",
                    "token": row.get("token") or "",
                }
    except Exception:
        return {}
    return out


def snapshot():
    """Names of f_* files present before a scan."""
    dirs = _cache_dirs()
    if not dirs:
        return set()
    _, _, cache_dir = dirs[0]
    try:
        return {os.path.basename(p) for p in glob.glob(os.path.join(cache_dir, "f_*"))}
    except OSError:
        return set()


def collect(limit=None, baseline=None):
    """Collect unique JPEG covers from the newest active CEF cache."""
    dirs = _cache_dirs()
    if not dirs:
        return {"ok": False, "reason": "没有找到 CEF Cache_Data 或 f_* 封面", "covers": [], "urls": 0}
    _, _, cache_dir = dirs[0]
    os.makedirs(COVER_DIR, exist_ok=True)
    url_map = load_url_map()
    files = []
    for p in glob.glob(os.path.join(cache_dir, "f_*")):
        try:
            name = os.path.basename(p)
            if baseline is not None and name in baseline:
                continue
            files.append((os.path.getmtime(p), name, p))
        except OSError:
            pass
    files.sort()
    seen = {}
    covers = []
    for mtime, name, path in files:
        sha = _jpeg_sha(path)
        if not sha:
            continue
        if sha in seen:
            continue
        idx = len(covers)
        out = os.path.join(COVER_DIR, f"idx_{idx:06d}.jpg")
        try:
            shutil.copy2(path, out)
        except OSError:
            continue
        meta = url_map.get(name) or {}
        code = meta.get("resource_code") or ""
        if code and code not in ("20304", "20350"):
            continue
        covers.append({
            "idx": idx, "file": name, "sha256": sha, "path": out,
            "mtime": datetime.fromtimestamp(mtime).isoformat(timespec="seconds"),
            "url": meta.get("url") or "",
            "resource_code": meta.get("resource_code") or "",
            "encfilekey": meta.get("encfilekey") or "",
            "m": meta.get("m") or "",
        })
        seen[sha] = idx
        if limit and len(covers) >= limit:
            break
    return {
        "ok": True,
        "cache_dir": cache_dir,
        "files": len(files),
        "covers": covers,
        "urls": sum(1 for c in covers if c["url"]),
        "duplicates": len(files) - len(covers),
    }


def attach(cards, info):
    """Attach cache cover by UIA index; persist the key -> cover mapping."""
    covers = (info or {}).get("covers") or []
    if not covers:
        return 0
    by_idx = {c["idx"]: c for c in covers}
    attached = 0
    saved = load_map()
    for card in cards:
        idx = card.get("index")
        if idx is None:
            continue
        c = by_idx.get(int(idx))
        if not c:
            continue
        card["cache_cover_path"] = c["path"]
        card["cover_source"] = "cef-cache"
        card["cache_cover_file"] = c["file"]
        if c.get("url"):
            card["cover_url"] = c["url"]
            card["cover_resource_code"] = c.get("resource_code")
            card["cover_encfilekey"] = c.get("encfilekey")
            card["cover_m"] = c.get("m")
        if card.get("key"):
            saved[card["key"]] = {
                "path": c["path"], "file": c["file"],
                "url": c.get("url") or "", "resource_code": c.get("resource_code") or "",
                "encfilekey": c.get("encfilekey") or "", "m": c.get("m") or "",
            }
        attached += 1
    save_map(saved)
    return attached


def attach_saved(cards, saved=None):
    """Reattach covers saved by a previous scan, matched by slot key."""
    saved = saved if saved is not None else load_map()
    n = 0
    for card in cards:
        rec = saved.get(card.get("key") or "")
        if not rec:
            continue
        path = rec.get("path") or ""
        if not path or not os.path.exists(path):
            continue
        card["cache_cover_path"] = path
        card["cover_source"] = "cef-cache"
        card["cache_cover_file"] = rec.get("file") or ""
        if rec.get("url"):
            card["cover_url"] = rec["url"]
            card["cover_resource_code"] = rec.get("resource_code") or ""
            card["cover_encfilekey"] = rec.get("encfilekey") or ""
            card["cover_m"] = rec.get("m") or ""
        n += 1
    return n


def summary(info):
    if not info:
        return "cache 封面：未运行"
    if not info.get("ok"):
        return "cache 封面：" + str(info.get("reason") or "失败")
    return (
        f"cache 封面：{info.get('covers') and len(info['covers']) or 0} 张唯一，"
        f"{info.get('files')} 个 f_*，{info.get('urls')} 条 URL，"
        f"dir={info.get('cache_dir')}"
    )
