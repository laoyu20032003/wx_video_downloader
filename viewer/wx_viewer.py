# -*- coding: utf-8 -*-
"""视频号卡片列表 / 封面 / 按卡激活下载（独立于微信主界面）。

流程：
  扫描：UIA 从顶部顺序翻页，读取作者主页全部卡片，截取可见封面
  下载：选中 slot → 重新定位当前 UIA 卡片 → hover/Invoke 激活
        → 扫描主进程新增 object_id ↔ URL → 用 wx-dl.ps1 落盘

依赖：comtypes、psutil、Pillow、tkinter、pwsh、ffmpeg/ffprobe。
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox

from PIL import Image, ImageTk

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WORK = os.path.join(HERE, "work")
LIB = os.path.join(WORK, "library.json")
BASELINE = os.path.join(WORK, "pairs_baseline.json")
SEED_JSON = os.path.join(WORK, "decodekey_map.json")
SEED_SCAN = os.path.join(HERE, "seed_scan.py")
RENDERER_SCAN = os.path.join(HERE, "renderer_scan.py")
DL_ENGINE = os.path.join(HERE, "dl_engine.py")
OUT_JSON = os.path.join(WORK, "uia_cards.json")
OUT_DIR = os.path.join(os.path.expanduser("~"), "Documents", "视频号")
TOOL = os.path.join(ROOT, "wx-dl.ps1")

sys.path.insert(0, HERE)
import uia_scan as scanmod
import main_pairs
import mem_render
import cache_covers


def load_lib():
    try:
        with open(LIB, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_lib(d):
    os.makedirs(WORK, exist_ok=True)
    with open(LIB, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)


def complete_url(url):
    return bool(url and "sign=" in url and "basedata=" in url and "\x00" not in url)


def load_baseline():
    try:
        with open(BASELINE, encoding="utf-8") as f:
            d = json.load(f)
        return {(str(x[0]), str(x[1])) for x in d if len(x) >= 2}
    except Exception:
        return set()


def save_baseline(rows):
    try:
        os.makedirs(WORK, exist_ok=True)
        data = [[r["object_id"], r["kind"]] for r in rows]
        with open(BASELINE, "w", encoding="utf-8") as f:
            json.dump(data, f)
    except Exception:
        pass


def clean_text(s):
    try:
        s = str(s).split("\x00", 1)[0]
        return "".join(ch for ch in s if 33 <= ord(ch) <= 126)
    except Exception:
        return ""


def load_seeds():
    try:
        with open(SEED_JSON, encoding="utf-8") as f:
            rows = json.load(f)
        out = {}
        for r in rows:
            if r.get("src") == "report" and r.get("oid") and r.get("decodeKey"):
                oid = str(r["oid"])
                seed = str(r["decodeKey"])
                arr = out.setdefault(oid, [])
                if seed not in arr:
                    arr.append(seed)
        return out
    except Exception:
        return {}


def ensure_seeds():
    if fresh(SEED_JSON, 600):
        return load_seeds()
    try:
        subprocess.run(
            [sys.executable.replace("pythonw.exe", "python.exe"), SEED_SCAN],
            capture_output=True, timeout=180, creationflags=CREATE_NO_WINDOW)
    except Exception:
        pass
    return load_seeds()


CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0


def run_hidden(args, **kwargs):
    """Run a console child without flashing a console window.

    The viewer is pythonw.exe, so a plain subprocess.run(pwsh/ffmpeg...)
    creates a new console for the child.  That is the window seen when
    the final file is saved.
    """
    kwargs.setdefault("creationflags", CREATE_NO_WINDOW)
    if os.name == "nt":
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        si.wShowWindow = 0  # SW_HIDE
        kwargs.setdefault("startupinfo", si)
    return subprocess.run(args, **kwargs)


def fresh(path, seconds):
    try:
        return os.path.exists(path) and (time.time() - os.path.getmtime(path)) < seconds
    except Exception:
        return False


def collect_render_models():
    total_pid, records = mem_render.scan_all()
    with open(os.path.join(WORK, "mem_model2.json"), "w", encoding="utf-8") as f:
        json.dump(records, f, ensure_ascii=False)
    return total_pid, records


def run_renderer_scan():
    """One pass over active renderers: cards + decodeKey/seed together."""
    run_hidden(
        [sys.executable.replace("pythonw.exe", "python.exe"), RENDERER_SCAN],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)


def run_resolve():
    run_hidden(
        [sys.executable.replace("pythonw.exe", "python.exe"),
         os.path.join(HERE, "resolve.py")],
        capture_output=True, timeout=120)
    with open(os.path.join(WORK, "resolved_cards.json"), encoding="utf-8") as f:
        return json.load(f)


class ScanWorker(threading.Thread):
    def __init__(self, q, force=False, capture_screenshots=True, use_cache=True):
        super().__init__(daemon=True)
        self.q = q
        self.force = force
        self.capture_screenshots = capture_screenshots
        self.use_cache = use_cache
        self.collector = None

    def run(self):
        try:
            c = scanmod.Collector(
                OUT_JSON, wait=0.75, max_pages=50, scroll=True,
                restore=True, cap=False, capture_covers=self.capture_screenshots)
            self.collector = c
            cache_baseline = cache_covers.snapshot() if self.use_cache else None
            def on_step(step, snap):
                self.q.put(("step", step, snap))
            snap = c.run(on_step)

            if self.use_cache:
                self.q.put(("status", "读取 CEF cache 封面…"))
                try:
                    saved_n = cache_covers.attach_saved(snap.get("cards") or [])
                    info = cache_covers.collect(baseline=cache_baseline)
                    info["baseline"] = len(cache_baseline or ())
                    info["saved"] = saved_n
                    snap["cache_cover"] = info
                    attached = cache_covers.attach(snap.get("cards") or [], info)
                    self.q.put(("cache_info", cache_covers.summary(info), attached, info))
                except Exception as e:
                    self.q.put(("cache_info", "cache 封面失败: " + str(e), 0, {}))

            # 跨层绑定：renderer 记录（oid/index/时长/点赞） + 主进程完整 URL
            self.q.put(("status", "扫描 renderer 模型…"))
            try:
                mem_path = os.path.join(WORK, "mem_model2.json")
                if self.force or not fresh(mem_path, 600):
                    run_renderer_scan()
                else:
                    # 即使卡片缓存新鲜，也补一次 seed 表（可能已有新 report）
                    if not fresh(SEED_JSON, 300):
                        ensure_seeds()
                self.q.put(("status", "扫描主进程完整 URL…"))
                pairs_path = os.path.join(WORK, "main_pairs.json")
                if not self.force and fresh(pairs_path, 600):
                    with open(pairs_path, encoding="utf-8") as f:
                        rows = json.load(f).get("rows") or []
                else:
                    pid, rows = main_pairs.scan()
                    with open(pairs_path, "w", encoding="utf-8") as f:
                        json.dump({"pid": pid, "rows": rows}, f, ensure_ascii=False)
                self.q.put(("status", "按 oid/序号/时长/点赞绑定…"))
                snap["resolved"] = run_resolve()
            except Exception as e:
                snap["resolve_error"] = str(e)

            self.q.put(("done", snap))
        except Exception as e:
            self.q.put(("error", str(e)))


class BaselineWorker(threading.Thread):
    def __init__(self, q):
        super().__init__(daemon=True)
        self.q = q

    def run(self):
        try:
            _, rows = main_pairs.scan()
            save_baseline(rows)
            self.q.put(("baseline", len(rows)))
        except Exception as e:
            self.q.put(("baseline_error", str(e)))


class CoverWorker(threading.Thread):
    """Explicit “补封面”: hover once, then take a new cache cover or screenshot."""

    def __init__(self, q, row, allow_screenshot, use_cache):
        super().__init__(daemon=True)
        self.q = q
        self.row = row
        self.key = row.get("key")
        self.allow_screenshot = allow_screenshot
        self.use_cache = use_cache

    def run(self):
        try:
            baseline = cache_covers.snapshot() if self.use_cache else set()
            c = scanmod.Collector(OUT_JSON, scroll=True, capture_covers=True)
            c._init_uia()
            c._pick_profile()
            card = c.find_card(self.key)
            if not card:
                self.q.put(("error", "补封面：当前 UIA 找不到这张卡", self.key))
                return
            c.hover(card, seconds=1.0)
            path = ""
            url = ""
            covers = []
            if self.use_cache:
                info = cache_covers.collect(baseline=baseline)
                covers = info.get("covers") or []
                if covers:
                    path = covers[0]["path"]
                    url = covers[0].get("url") or ""
            if not path and self.allow_screenshot:
                path = c._capture_cover(card)
            if not path:
                self.q.put(("error", "补封面：本次没有新增 cache，截图 fallback 也关闭", self.key))
                return
            self.q.put(("cover", {
                "key": self.key,
                "path": path,
                "url": url,
                "cache": bool(covers),
                "file": covers[0].get("file") if covers else "",
            }))
        except Exception as e:
            self.q.put(("error", "补封面失败: " + str(e), self.key))


class DownloadWorker(threading.Thread):
    """Per-row downloader. Pending rows are hovered for 8s, then rebound by oid/index."""

    def __init__(self, q, row):
        super().__init__(daemon=True)
        self.q = q
        self.row = row
        self.key = row.get("key")

    def run(self):
        try:
            key = self.row.get("key")
            url0 = clean_text(self.row.get("url") or "")
            oid0 = self.row.get("object_id")

            if complete_url(url0) and oid0:
                if ensure_seeds().get(str(oid0)):
                    self.q.put(("rowstatus", key, "seed"))
                    self.q.put(("status", f"seed 自解密下载 oid={oid0}"))
                    self.q.put(("bound", {"key": key, "object_id": oid0, "url": url0}))
                    saved, reason = self._try_seeds(url0, oid0)
                    if saved:
                        self.q.put(("saved", {"key": key, "file": saved,
                                              "object_id": oid0, "url": url0}))
                        return
                    self.q.put(("status", f"seed 不可用，回退 hover（{reason}）"))

            c = scanmod.Collector(OUT_JSON, scroll=True)
            c._init_uia()
            c._pick_profile()
            self.q.put(("status", "定位卡片…"))
            card = c.find_card(key)
            if not card:
                self.q.put(("status", "定位失败，正在诊断当前 UIA 候选…"))
                d = c.diagnose(key)
                msg = (
                    f"找不到卡片：viewer序号={self.row.get('index')} "
                    f"目标={self.row.get('duration','')}|{self.row.get('like','')}|"
                    f"{(self.row.get('desc') or '')[:24]}；"
                    f"定位={getattr(c, 'last_find_reason', '') or '未知'}；"
                    f"当前账号={d.get('account','?')}，UIA={d.get('cards')}张/"
                    f"可见{d.get('visible')}张，同时长{d.get('same_duration')}，"
                    f"时长+点赞{d.get('same_duration_like')}，同文案{d.get('same_desc')}；"
                    f"候选={d.get('examples')}"
                )
                self.q.put(("status", "定位失败：查看日志候选，先切回该作者主页并滚到目标附近"))
                self.q.put(("error", msg, key))
                return

            # 无论 ready 还是 pending，都先 hover 8 秒：
            # ready 需要明文头；pending 还需要让 renderer 建立 oid/URL 记录。
            self.q.put(("rowstatus", key, "hovering"))
            self.q.put(("status", "hover 8 秒（不点击播放）…"))
            c.hover(card, seconds=8.0)

            url = clean_text(self.row.get("url") or "")
            oid = self.row.get("object_id")
            if not complete_url(url):
                self.q.put(("status", "重新扫描 oid ↔ URL…"))
                url, oid = self._refresh_binding()
                if oid:
                    self.q.put(("oid", key, oid))
                if not complete_url(url):
                    self.q.put(("error", "hover 后仍没有可绑定的完整 URL", key))
                    return

            self.q.put(("bound", {"key": key, "object_id": oid, "url": url}))
            self.q.put(("status", "下载中（wx-dl）…"))
            saved, reason = self._download(url, oid or "slot", self.row)
            if saved:
                self.q.put(("saved", {"key": key, "file": saved,
                                      "object_id": oid, "url": url}))
            else:
                self.q.put(("failed", reason, key))
        except Exception as e:
            self.q.put(("error", str(e), self.key))

    def _resolve(self):
        run_renderer_scan()
        return run_resolve().get("rows") or []

    def _refresh_binding(self):
        idx = self.row.get("index")
        rows = self._resolve()
        rec = next((x for x in rows if x.get("index") == idx), None)
        oid_hint = rec.get("object_id") if rec else None
        if rec and complete_url(clean_text(rec.get("url") or "")):
            return clean_text(rec["url"]), rec.get("object_id")

        # 缓存里没有完整 URL 时，才扫一次主进程；不是每次点击都扫。
        pid, pairs = main_pairs.scan()
        with open(os.path.join(WORK, "main_pairs.json"), "w", encoding="utf-8") as f:
            json.dump({"pid": pid, "rows": pairs}, f, ensure_ascii=False)
        rows = self._resolve()
        rec = next((x for x in rows if x.get("index") == idx), None)
        if rec:
            return (clean_text(rec.get("url") or ""),
                    rec.get("object_id") or oid_hint)
        return "", oid_hint

    def _try_seeds(self, url, oid):
        seeds = ensure_seeds().get(str(oid), [])
        last = "没有 seed"
        for i, seed in enumerate(seeds):
            self.q.put(("status", f"seed 自解密 oid={oid} seed={seed}（{i + 1}/{len(seeds)}）"))
            saved, reason = self._download_seed(url, oid, seed)
            if saved:
                return saved, ""
            last = reason
        return "", last

    def _download_seed(self, url, oid, seed):
        sec = int(self.row.get("seconds") or 0)
        tag = "".join(ch for ch in clean_text(oid) if ch.isalnum()) or "seed"
        args = [
            sys.executable.replace("pythonw.exe", "python.exe"),
            DL_ENGINE, "--url", url, "--seed", str(seed), "--tag", tag,
            "--outdir", OUT_DIR, "--work", WORK,
        ]
        if sec > 0:
            args += ["--expected-duration", str(sec)]
        try:
            p = run_hidden(args, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=600)
            out = (p.stdout or "") + "\n" + (p.stderr or "")
            for line in out.splitlines():
                if line.startswith("SAVED="):
                    return line.split("=", 1)[1].strip(), ""
            lines = [x.strip() for x in out.splitlines() if x.strip()]
            for line in reversed(lines):
                if line not in ("FAILED",):
                    return "", line
            return "", "seed 自解密失败"
        except Exception as e:
            return "", "seed 下载失败: " + str(e)

    def _download(self, url, oid, row):
        url = clean_text(url)
        tag = "".join(ch for ch in clean_text(oid) if ch.isalnum()) or "slot"
        try:
            code = run_hidden(
                ["curl.exe", "-s", "-o", "NUL", "--noproxy", "*", "-m", "12",
                 "-I", "-H", "Referer: https://liteapp.weixin.qq.com/",
                 "-A", "Mozilla/5.0", "-w", "%{http_code}", url],
                capture_output=True, text=True, timeout=20).stdout.strip()
        except Exception as e:
            return "", "URL HEAD 失败: " + str(e)
        if code not in ("200", "206"):
            return "", f"URL HEAD HTTP {code}（残缺/过期，需要重新取流）"

        sec = int(row.get("seconds") or 0)
        args = [
            "pwsh.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", TOOL, "-SaveUrl", url, "-SaveTag", tag,
            "-OutDir", OUT_DIR,
        ]
        if sec > 0:
            args += ["-ExpectedDuration", str(sec)]
        try:
            p = run_hidden(args, capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=600)
            out = (p.stdout or "") + "\n" + (p.stderr or "")
            for line in out.splitlines():
                if line.startswith("SAVED="):
                    return line.split("=", 1)[1].strip(), ""
            lines = [x.strip() for x in out.splitlines() if x.strip()]
            for line in reversed(lines):
                if line == "FAILED":
                    continue
                if any(k in line for k in ("预检", "配对", "内存", "时长", "下载失败", "HTTP", "候选", "明文头")):
                    return "", line
            for line in reversed(lines):
                if line != "FAILED":
                    return "", line
            return "", "FAILED"
        except Exception as e:
            return "", str(e)

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("视频号卡片 / 下载")
        self.geometry("1160x720")
        self.q = queue.Queue()
        self.lib = load_lib()
        self.log_path = os.path.join(WORK, "viewer.log")
        self.cards = []
        self.photos = []
        self.page = 0
        self.page_size = 20
        self.current_account = None
        self.last_error = ""
        self.use_cache_cover = tk.BooleanVar(value=True)
        self.allow_screenshot = tk.BooleanVar(value=True)
        self.progress = None
        self.worker = None
        self.scanner = None
        self._build()
        self.after(400, self.start_scan)
        self.after(200, self.poll)

    def _build(self):
        bar = tk.Frame(self)
        bar.pack(fill="x", padx=8, pady=6)
        self.scan_btn = ttk.Button(bar, text="重新扫描", command=lambda: self.start_scan(True))
        self.dl_btn = ttk.Button(bar, text="下载选中", command=self.download_selected)
        self.cover_btn = ttk.Button(bar, text="补封面", command=self.cover_selected)
        self.stop_btn = ttk.Button(bar, text="停止", command=self.stop)
        self.status = ttk.Label(bar, text="准备")
        self.account = ttk.Label(bar, text="账号: -")
        self.prev_btn = ttk.Button(bar, text="上一页", command=self.prev_page)
        self.next_btn = ttk.Button(bar, text="下一页", command=self.next_page)
        self.page_label = ttk.Label(bar, text="1/1")
        self.scan_btn.pack(side="left")
        self.dl_btn.pack(side="left", padx=6)
        self.cover_btn.pack(side="left")
        self.stop_btn.pack(side="left", padx=6)
        self.account.pack(side="left", padx=12)
        self.prev_btn.pack(side="left", padx=(8, 2))
        self.page_label.pack(side="left")
        self.next_btn.pack(side="left", padx=2)
        self.status.pack(side="left", padx=8)

        opts = tk.Frame(self)
        opts.pack(fill="x", padx=10, pady=(0, 2))
        ttk.Checkbutton(opts, text="优先使用 CEF cache 封面",
                        variable=self.use_cache_cover,
                        command=self.on_cover_toggle).pack(side="left")
        ttk.Checkbutton(opts, text="允许屏幕截图 fallback",
                        variable=self.allow_screenshot,
                        command=self.on_cover_toggle).pack(side="left", padx=10)
        self.cache_status = ttk.Label(opts, text="cache: -", foreground="#666")
        self.cache_status.pack(side="left", padx=8)

        style = ttk.Style(self)
        style.configure("Treeview", rowheight=96)
        self.tree = ttk.Treeview(self, show="tree headings",
                                 columns=("seq", "dur", "like", "status", "oid", "act", "desc"))
        self.tree.heading("#0", text="封面")
        self.tree.column("#0", width=72, anchor="center")
        for c, t, w in (("seq", "序号", 50), ("dur", "时长", 65),
                        ("like", "点赞", 65), ("status", "状态", 80),
                        ("oid", "OID", 150), ("act", "操作", 65),
                        ("desc", "文案", 520)):
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w, anchor="w")
        self.tree.column("act", anchor="center")
        self.tree.pack(fill="both", expand=True, padx=8, pady=4)
        self.tree.bind("<Button-1>", self.on_tree_click)
        self.tree.bind("<Double-1>", lambda e: self.download_selected())

        self.hint = ttk.Label(
            self,
            text="找不到卡片时：确认微信停留在该作者主页，先手动滚到目标卡附近再点下载；"
                 "日志会列出当前 UIA 的同名/同时长候选。",
            foreground="#555")
        self.hint.pack(fill="x", padx=8, pady=(0, 2))

        logbar = tk.Frame(self)
        logbar.pack(fill="x", padx=8)
        ttk.Button(logbar, text="复制日志", command=self.copy_log).pack(side="left")
        ttk.Button(logbar, text="复制最后错误", command=self.copy_error).pack(side="left", padx=6)
        ttk.Label(logbar, text="日志可直接选中；Ctrl+C 也可复制全部",
                  foreground="#777").pack(side="left", padx=8)

        self.log = tk.Text(self, height=10, state="disabled")
        self.log.pack(fill="x", padx=8, pady=(0, 8))
        self.log.bind("<Control-c>", lambda e: self.copy_log())

    def _progress(self, text):
        try:
            if getattr(self, "progress", None) and self.progress.winfo_exists():
                self.progress_label.configure(text=str(text))
                self.progress.lift()
        except Exception:
            pass

    def logline(self, text):
        line = time.strftime("%H:%M:%S ") + str(text)
        try:
            os.makedirs(WORK, exist_ok=True)
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            pass
        self.log.configure(state="normal")
        self.log.insert("end", line + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def on_cover_toggle(self):
        # 只刷新封面列，保留每行的值、选择和页面
        self.refresh_covers()

    def _photo_for(self, c):
        p = ""
        if self.use_cache_cover.get() and c.get("cache_cover_path"):
            p = c["cache_cover_path"]
        elif self.allow_screenshot.get() and c.get("screenshot_cover_path"):
            p = c["screenshot_cover_path"]
        if not p or not os.path.exists(p):
            return None
        try:
            im = Image.open(p)
            im.thumbnail((64, 90))
            photo = ImageTk.PhotoImage(im)
            self.photos.append(photo)
            return photo
        except Exception:
            return None

    def refresh_covers(self):
        self.photos = []
        start = self.page * self.page_size
        for off, item in enumerate(self.tree.get_children()):
            idx = start + off
            if idx >= len(self.cards):
                break
            self.tree.item(item, image=self._photo_for(self.cards[idx]))

    def copy_log(self):
        try:
            text = self.log.get("1.0", "end").strip()
            if not text:
                text = "（暂无日志）"
            self.clipboard_clear()
            self.clipboard_append(text)
            self.status.configure(text="日志已复制")
        except Exception as e:
            self.status.configure(text="复制失败: " + str(e))

    def copy_error(self):
        try:
            text = self.last_error or "（暂无错误）"
            self.clipboard_clear()
            self.clipboard_append(text)
            self.status.configure(text="最后错误已复制")
        except Exception as e:
            self.status.configure(text="复制失败: " + str(e))

    def start_scan(self, force=False):
        if self.worker and self.worker.is_alive():
            return
        # 每次扫描都先清空旧列表，避免自动扫描失败时继续显示上一个账号/上一次的卡片
        self.cards = []
        self.page = 0
        self.tree.delete(*self.tree.get_children())
        self.scan_btn.configure(state="disabled")
        self.dl_btn.configure(state="disabled")
        self.status.configure(text="采集中…")
        self.withdraw()  # 避免窗口遮住微信卡片，影响封面截图
        # 主窗口隐藏时也必须让用户看到进度；放在屏幕左上，避开视频号卡片。
        if not getattr(self, "progress", None) or not self.progress.winfo_exists():
            self.progress = tk.Toplevel(self)
            self.progress.title("视频号扫描")
            self.progress.geometry("420x110+10+10")
            self.progress.attributes("-topmost", True)
            self.progress_label = ttk.Label(
                self.progress, text="准备扫描…", wraplength=390, justify="left")
            self.progress_label.pack(fill="both", expand=True, padx=12, pady=12)
        self.progress.deiconify()
        self.progress_label.configure(text="准备扫描…")
        self.scanner = ScanWorker(
            self.q, force=force,
            capture_screenshots=self.allow_screenshot.get(),
            use_cache=self.use_cache_cover.get())
        self.scanner.start()

    def stop(self):
        if self.scanner and self.scanner.collector:
            self.scanner.collector.stop_flag = True

    def poll(self):
        try:
            while True:
                item = self.q.get_nowait()
                kind = item[0]
                if kind == "step":
                    _, step, snap = item
                    msg = f"第 {step['page']} 页 · 已发现 {step['unique']} · 新增 {step['new']}"
                    self.status.configure(text=msg)
                    self._progress(msg)
                elif kind == "done":
                    self._close_progress()
                    self.on_scan_done(item[1])
                elif kind == "error":
                    self._close_progress()
                    self.deiconify()
                    key = item[2] if len(item) > 2 else None
                    row = self.row_by_key(key) or self.selected()
                    if row:
                        row["status"] = "failed"
                        row["error"] = item[1]
                        row["account"] = self.current_account
                        self.lib[row["key"]] = row
                        save_lib(self.lib)
                    self.status.configure(text="失败: " + item[1])
                    self.last_error = item[1]
                    self.logline("ERROR " + item[1])
                    if len(item) <= 2:
                        # 扫描失败时不要继续显示上一次的旧卡片
                        self.cards = []
                        self.page = 0
                        self.render()
                    self.scan_btn.configure(state="normal")
                    self.dl_btn.configure(state="normal")
                    self.cover_btn.configure(state="normal")
                    self.render()
                elif kind == "baseline":
                    self.logline(f"主进程配对基线已建立: {item[1]}")
                elif kind == "baseline_error":
                    self.logline("主进程配对基线失败: " + item[1])
                elif kind == "rowstatus":
                    _, rk, rs = item
                    row = self.row_by_key(rk)
                    if row:
                        row["status"] = rs
                        self.render()
                elif kind == "cache_info":
                    msg, attached, info = item[1], item[2], item[3]
                    self.cache_status.configure(
                        text=f"cache 封面: 映射 {attached} 张" if info.get("ok") else "cache: 无")
                    self.logline(msg + f"；映射 {attached} 张；复用上次 {info.get('saved',0)} 张；baseline={info.get('baseline','?')}")
                    for c in (info.get("covers") or [])[:8]:
                        if c.get("url"):
                            self.logline(
                                f"cache idx={c.get('idx')} file={c.get('file')} "
                                f"code={c.get('resource_code')} url={c.get('url')[:140]}")
                        else:
                            self.logline(
                                f"cache idx={c.get('idx')} file={c.get('file')} url=（无离线元数据）")
                elif kind == "cover":
                    d = item[1]
                    row = self.row_by_key(d.get("key"))
                    if row:
                        if d.get("cache"):
                            row["cache_cover_path"] = d["path"]
                            row["cache_cover_file"] = d.get("file") or ""
                            row["cover_source"] = "cef-cache"
                            if d.get("url"):
                                row["cover_url"] = d["url"]
                        else:
                            row["screenshot_cover_path"] = d["path"]
                            row["cover_source"] = "screenshot"
                    self.status.configure(text="封面已更新")
                    self.logline(
                        f"封面更新: {d.get('key','')[:24]} source="
                        f"{'cache' if d.get('cache') else 'screenshot'}")
                    self.render()
                    self.dl_btn.configure(state="normal")
                    self.cover_btn.configure(state="normal")
                elif kind == "status":
                    self.status.configure(text=item[1])
                    self._progress(item[1])
                    self.logline(item[1])
                elif kind == "oid":
                    _, rk, oid = item
                    row = self.row_by_key(rk)
                    if row and oid:
                        row["object_id"] = oid
                        self.lib[row["key"]] = row
                        save_lib(self.lib)
                        self.logline(f"OID 已回填: {oid}")
                        self.render()
                elif kind == "bound":
                    d = item[1]
                    row = self.row_by_key(d.get("key")) or self.selected()
                    if row:
                        row["object_id"] = d.get("object_id")
                        row["url"] = d.get("url")
                        row["status"] = "downloading"
                        row["account"] = self.current_account
                        self.lib[row["key"]] = row
                        save_lib(self.lib)
                    self.logline(f"bound oid={d.get('object_id')}")
                    self.render()
                elif kind == "saved":
                    d = item[1]
                    row = self.row_by_key(d.get("key")) or self.selected()
                    if row:
                        row["file"] = d["file"]
                        row["status"] = "done"
                        row["object_id"] = d.get("object_id")
                        row["url"] = d.get("url")
                        row["account"] = self.current_account
                        self.lib[row["key"]] = row
                        save_lib(self.lib)
                    self.deiconify()
                    self.status.configure(text="已保存: " + d["file"])
                    self.logline("SAVED " + d["file"])
                    self.render()
                    self.scan_btn.configure(state="normal")
                    self.dl_btn.configure(state="normal")
                    self.cover_btn.configure(state="normal")
                elif kind == "failed":
                    self.deiconify()
                    key = item[2] if len(item) > 2 else None
                    row = self.row_by_key(key) or self.selected()
                    if row:
                        row["status"] = "failed"
                        row["error"] = item[1]
                        row["account"] = self.current_account
                        self.lib[row["key"]] = row
                        save_lib(self.lib)
                    self.status.configure(text="失败: " + item[1])
                    self.last_error = item[1]
                    self.logline("FAILED " + item[1])
                    self.render()
                    self.scan_btn.configure(state="normal")
                    self.dl_btn.configure(state="normal")
                    self.cover_btn.configure(state="normal")
        except queue.Empty:
            pass
        self.after(150, self.poll)

    def _close_progress(self):
        try:
            if getattr(self, "progress", None) and self.progress.winfo_exists():
                self.progress.destroy()
        except Exception:
            pass
        self.progress = None

    def on_scan_done(self, snap):
        self._close_progress()
        self.deiconify()
        new_account = snap.get("account") or "-"
        changed = bool(self.current_account and new_account != self.current_account)
        self.current_account = new_account
        self.cards = snap.get("cards", [])
        for c in self.cards:
            # 保留两种来源：渲染时按当前 checkbox 动态选择
            c["screenshot_cover_path"] = c.get("cover_path") or ""
        if changed:
            self.page = 0
            self.logline(f"账号已切换: {new_account}，已清空旧列表状态")
        resolved = (snap.get("resolved") or {}).get("rows") or []
        by_idx = {r.get("index"): r for r in resolved if r.get("index") is not None}
        for c in self.cards:
            r = by_idx.get(c.get("index"))
            if r:
                c["object_id"] = r.get("object_id")
                c["nonce"] = r.get("nonce")
                c["url"] = r.get("url") or ""
                c["status"] = r.get("status") or "pending"
                c["note"] = r.get("note") or ""
                c["like_check"] = r.get("like_check")
                c["pos_check"] = r.get("pos_check")
            else:
                c["status"] = "pending"
        # 合并已下载文件状态；旧账号/旧 URL 不能覆盖本次解析结果。
        for c in self.cards:
            old = self.lib.get(c["key"], {})
            if old.get("account") not in (None, new_account):
                old = {}
            if not c.get("object_id") and old.get("object_id"):
                c["object_id"] = old["object_id"]
            if old.get("file") and os.path.exists(old["file"]):
                c["file"] = old["file"]
                c["status"] = "done"
        self.account.configure(text="账号: " + new_account)
        prefix = "账号已切换 · " if changed else ""
        self.status.configure(
            text=f"{prefix}完成 · {snap.get('discovered',0)} 张 · {snap.get('total_text','')}")
        self.render()
        self.scan_btn.configure(state="normal")
        self.dl_btn.configure(state="normal")
        self.cover_btn.configure(state="normal")

    def render(self):
        self.tree.delete(*self.tree.get_children())
        self.photos = []
        total = max(1, (len(self.cards) + self.page_size - 1) // self.page_size)
        self.page = max(0, min(self.page, total - 1))
        self.page_label.configure(text=f"{self.page + 1}/{total}")
        start = self.page * self.page_size
        subset = self.cards[start:start + self.page_size]
        for off, c in enumerate(subset):
            i = start + off
            photo = self._photo_for(c)
            st = c.get("status", "pending")
            self.tree.insert("", "end", image=photo, values=(
                i + 1, c.get("duration", ""), c.get("like", ""), st,
                c.get("object_id") or "", "下载", (c.get("desc") or "")[:110]))

    def prev_page(self):
        if self.page > 0:
            self.page -= 1
            self.render()

    def next_page(self):
        total = max(1, (len(self.cards) + self.page_size - 1) // self.page_size)
        if self.page + 1 < total:
            self.page += 1
            self.render()

    def on_tree_click(self, event):
        if self.tree.identify_region(event.x, event.y) != "cell":
            return
        if self.tree.identify_column(event.x) != "#6":
            return
        rid = self.tree.identify_row(event.y)
        if not rid:
            return
        i = self.page * self.page_size + self.tree.index(rid)
        if 0 <= i < len(self.cards):
            self.tree.selection_set(rid)
            self.download_row(self.cards[i])

    def selected(self):
        items = self.tree.selection()
        if not items:
            return None
        i = self.page * self.page_size + self.tree.index(items[0])
        return self.cards[i] if 0 <= i < len(self.cards) else None

    def row_by_key(self, key):
        if not key:
            return None
        for c in self.cards:
            if c.get("key") == key:
                return c
        return None

    def cover_selected(self):
        row = self.selected()
        if not row:
            messagebox.showinfo("提示", "先选中一行")
            return
        if self.worker and self.worker.is_alive():
            messagebox.showinfo("提示", "已有任务在运行")
            return
        self.dl_btn.configure(state="disabled")
        self.cover_btn.configure(state="disabled")
        self.status.configure(text="补封面：hover 1 秒…")
        self.worker = CoverWorker(
            self.q, dict(row),
            allow_screenshot=self.allow_screenshot.get(),
            use_cache=self.use_cache_cover.get())
        self.worker.start()

    def download_selected(self):
        row = self.selected()
        if not row:
            messagebox.showinfo("提示", "先选中一行")
            return
        self.download_row(row)

    def download_row(self, row):
        if row.get("file") and os.path.exists(row["file"]):
            os.startfile(os.path.dirname(row["file"]))
            return
        if self.worker and self.worker.is_alive():
            messagebox.showinfo("提示", "已有下载任务在运行")
            return
        self.dl_btn.configure(state="disabled")
        self.status.configure(text="下载任务开始…")
        row["status"] = "queued"
        row["account"] = self.current_account
        self.render()
        self.worker = DownloadWorker(self.q, dict(row))
        self.worker.start()


if __name__ == "__main__":
    os.makedirs(WORK, exist_ok=True)
    App().mainloop()
