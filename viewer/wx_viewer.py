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
SEND_TRIGGER = os.path.join(HERE, "send_trigger.py")
DL_ENGINE = os.path.join(HERE, "dl_engine.py")
OUT_JSON = os.path.join(WORK, "uia_cards.json")
OUT_DIR = os.path.join(os.path.expanduser("~"), "Documents", "视频号")
TOOL = os.path.join(ROOT, "wx-dl.ps1")
ACTIVATION = os.environ.get("WX_VIEWER_ACTIVATION", "hover").lower()

sys.path.insert(0, HERE)
import uia_scan as scanmod
import main_pairs
import mem_render


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
                out.setdefault(str(r["oid"]), str(r["decodeKey"]))
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
    def __init__(self, q, force=False):
        super().__init__(daemon=True)
        self.q = q
        self.force = force
        self.collector = None

    def run(self):
        try:
            c = scanmod.Collector(
                OUT_JSON, wait=0.75, max_pages=50, scroll=True,
                restore=True, cap=False, capture_covers=True)
            self.collector = c
            def on_step(step, snap):
                self.q.put(("step", step, snap))
            snap = c.run(on_step)

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

            # Experimental: Doubao-style PostMessage right-click play.
            # It never moves the global cursor; if it fails we fall back to hover.
            if ACTIVATION == "send":
                self.q.put(("rowstatus", key, "send"))
                self.q.put(("status", "send-event 右键播放…"))
                ok, why = self._send_play()
                if ok:
                    time.sleep(2.0)
                    url = url0
                    oid = oid0
                    if not complete_url(url):
                        url, oid = self._refresh_binding()
                    if complete_url(url):
                        seed = ensure_seeds().get(str(oid)) if oid else None
                        self.q.put(("bound", {"key": key, "object_id": oid, "url": url}))
                        if seed:
                            self.q.put(("status", f"send-event 后 seed 下载 oid={oid}"))
                            saved, reason = self._download_seed(url, oid, seed)
                        else:
                            self.q.put(("status", "send-event 后下载中（wx-dl）…"))
                            saved, reason = self._download(url, oid or "slot", self.row)
                        self._send_close()
                        if saved:
                            self.q.put(("saved", {"key": key, "file": saved,
                                                  "object_id": oid, "url": url}))
                        else:
                            self.q.put(("failed", reason, key))
                        return
                    self._send_close()
                    self.q.put(("status", f"send-event 未绑定 URL，回退 hover（{why}）"))
                else:
                    self.q.put(("status", f"send-event 失败，回退 hover（{why}）"))

            if complete_url(url0) and oid0:
                seed = ensure_seeds().get(str(oid0))
                if seed:
                    self.q.put(("rowstatus", key, "seed"))
                    self.q.put(("status", f"seed 自解密下载 oid={oid0} seed={seed}"))
                    self.q.put(("bound", {"key": key, "object_id": oid0, "url": url0}))
                    saved, reason = self._download_seed(url0, oid0, seed)
                    if saved:
                        self.q.put(("saved", {"key": key, "file": saved,
                                              "object_id": oid0, "url": url0}))
                    else:
                        self.q.put(("failed", reason, key))
                    return

            c = scanmod.Collector(OUT_JSON, scroll=True)
            c._init_uia()
            c._pick_profile()
            self.q.put(("status", "定位卡片…"))
            card = c.find_card(key)
            if not card:
                self.q.put(("error", "当前 UIA 网格里找不到这张卡", key))
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

    def _send_play(self):
        desc = (self.row.get("desc") or "")[:12]
        sec = int(self.row.get("seconds") or 0)
        args = [sys.executable.replace("pythonw.exe", "python.exe"),
                SEND_TRIGGER, "--desc", desc, "--seconds", str(sec)]
        like = self.row.get("like_int")
        if like is not None:
            args += ["--like", str(int(like))]
        try:
            p = run_hidden(args, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=45)
            out = (p.stdout or "").strip().splitlines()
            if not out:
                return False, "no output"
            r = json.loads(out[-1])
            return bool(r.get("ok")), str(r.get("reason") or "")
        except Exception as e:
            return False, str(e)

    def _send_close(self):
        try:
            run_hidden([sys.executable.replace("pythonw.exe", "python.exe"),
                        SEND_TRIGGER, "--close-tab"],
                       capture_output=True, text=True, timeout=30)
        except Exception:
            pass

    def _resolve(self):
        run_renderer_scan()
        return run_resolve().get("rows") or []

    def _refresh_binding(self):
        idx = self.row.get("index")
        rows = self._resolve()
        rec = next((x for x in rows if x.get("index") == idx), None)
        if rec and complete_url(clean_text(rec.get("url") or "")):
            return clean_text(rec["url"]), rec.get("object_id")

        # 缓存里没有完整 URL 时，才扫一次主进程；不是每次点击都扫。
        pid, pairs = main_pairs.scan()
        with open(os.path.join(WORK, "main_pairs.json"), "w", encoding="utf-8") as f:
            json.dump({"pid": pid, "rows": pairs}, f, ensure_ascii=False)
        rows = self._resolve()
        rec = next((x for x in rows if x.get("index") == idx), None)
        if rec and complete_url(clean_text(rec.get("url") or "")):
            return clean_text(rec["url"]), rec.get("object_id")
        return "", None

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
        suffix = " (send-event)" if ACTIVATION == "send" else ""
        self.title("视频号卡片 / 下载" + suffix)
        self.geometry("1160x720")
        self.q = queue.Queue()
        self.lib = load_lib()
        self.log_path = os.path.join(WORK, "viewer.log")
        self.cards = []
        self.photos = []
        self.page = 0
        self.page_size = 20
        self.current_account = None
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
        self.stop_btn = ttk.Button(bar, text="停止", command=self.stop)
        self.status = ttk.Label(bar, text="准备")
        self.account = ttk.Label(bar, text="账号: -")
        self.prev_btn = ttk.Button(bar, text="上一页", command=self.prev_page)
        self.next_btn = ttk.Button(bar, text="下一页", command=self.next_page)
        self.page_label = ttk.Label(bar, text="1/1")
        self.scan_btn.pack(side="left")
        self.dl_btn.pack(side="left", padx=6)
        self.stop_btn.pack(side="left")
        self.account.pack(side="left", padx=12)
        self.prev_btn.pack(side="left", padx=(8, 2))
        self.page_label.pack(side="left")
        self.next_btn.pack(side="left", padx=2)
        self.status.pack(side="left", padx=8)

        style = ttk.Style(self)
        style.configure("Treeview", rowheight=96)
        self.tree = ttk.Treeview(self, show="tree headings",
                                 columns=("seq", "dur", "like", "status", "act", "desc"))
        self.tree.heading("#0", text="封面")
        self.tree.column("#0", width=72, anchor="center")
        for c, t, w in (("seq", "序号", 50), ("dur", "时长", 65),
                        ("like", "点赞", 65), ("status", "状态", 85),
                        ("act", "操作", 70), ("desc", "文案", 700)):
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w, anchor="w")
        self.tree.column("act", anchor="center")
        self.tree.pack(fill="both", expand=True, padx=8, pady=4)
        self.tree.bind("<Button-1>", self.on_tree_click)
        self.tree.bind("<Double-1>", lambda e: self.download_selected())

        self.log = tk.Text(self, height=7, state="disabled")
        self.log.pack(fill="x", padx=8, pady=(0, 8))

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

    def start_scan(self, force=False):
        if self.worker and self.worker.is_alive():
            return
        # 手动“重新扫描”必须清掉旧账号/旧页面的展示与缓存依赖。
        if force:
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
        self.scanner = ScanWorker(self.q, force=force)
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
                    self.logline("ERROR " + item[1])
                    self.scan_btn.configure(state="normal")
                    self.dl_btn.configure(state="normal")
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
                elif kind == "status":
                    self.status.configure(text=item[1])
                    self._progress(item[1])
                    self.logline(item[1])
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
                    self.logline("FAILED " + item[1])
                    self.render()
                    self.scan_btn.configure(state="normal")
                    self.dl_btn.configure(state="normal")
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
            photo = None
            p = c.get("cover_path") or ""
            if p and os.path.exists(p):
                try:
                    im = Image.open(p)
                    im.thumbnail((64, 90))
                    photo = ImageTk.PhotoImage(im)
                    self.photos.append(photo)
                except Exception:
                    photo = None
            st = c.get("status", "pending")
            self.tree.insert("", "end", image=photo, values=(
                i + 1, c.get("duration", ""), c.get("like", ""), st,
                "下载", (c.get("desc") or "")[:110]))

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
        if self.tree.identify_column(event.x) != "#5":
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
