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
OUT_JSON = os.path.join(WORK, "uia_cards.json")
OUT_DIR = os.path.join(os.path.expanduser("~"), "Documents", "视频号")
TOOL = os.path.join(ROOT, "wx-dl.ps1")

sys.path.insert(0, HERE)
import uia_scan as scanmod
import main_pairs


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
    return bool(url and "sign=" in url and "basedata=" in url)


class ScanWorker(threading.Thread):
    def __init__(self, q):
        super().__init__(daemon=True)
        self.q = q
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
            self.q.put(("done", snap))
        except Exception as e:
            self.q.put(("error", str(e)))


class ActivateWorker(threading.Thread):
    def __init__(self, q, row):
        super().__init__(daemon=True)
        self.q = q
        self.row = row

    def run(self):
        c = None
        try:
            key = self.row.get("key")
            self.q.put(("status", "定位卡片…"))
            c = scanmod.Collector(OUT_JSON, scroll=True)
            c._init_uia()
            c._pick_profile()
            card = c.find_card(key)
            if not card:
                self.q.put(("error", "当前 UIA 网格里找不到这张卡（可能文案/时长变了，或存在重复）"))
                return

            self.q.put(("status", "扫描激活前配对…"))
            try:
                _, before = main_pairs.scan()
            except Exception:
                before = []

            # 先 hover，不打开播放器
            self.q.put(("status", "hover 激活取流…"))
            c.hover(card, seconds=2.2)
            time.sleep(1.0)
            try:
                _, after = main_pairs.scan()
            except Exception:
                after = []
            new = main_pairs.delta(before, after)

            # hover 没有新配对时，Invoke 打开播放器强制解码
            used_invoke = False
            if not [r for r in new if r["kind"] == "20302"]:
                self.q.put(("status", "Invoke 播放取流…"))
                if c.invoke(card):
                    used_invoke = True
                    time.sleep(2.5)
                    try:
                        _, after2 = main_pairs.scan()
                    except Exception:
                        after2 = after
                    new = main_pairs.delta(before, after2)
                    c.close_player()
                else:
                    c.close_player()

            self.q.put(("status", "匹配 object_id ↔ URL…"))
            pair = self._choose(new, self.row)
            if not pair:
                self.q.put(("error", "激活后没有唯一可信的 object_id↔URL；保持 pending"))
                return

            url = pair["raw_url"]
            oid = pair["object_id"]
            self.q.put(("bound", {"object_id": oid, "url": url,
                                  "invoke": used_invoke, "meta": pair.get("meta")}))

            self.q.put(("status", "下载中（wx-dl）…"))
            saved, reason = self._download(url, oid, self.row)
            if saved:
                self.q.put(("saved", {"file": saved, "object_id": oid, "url": url}))
            else:
                self.q.put(("failed", reason))
        except Exception as e:
            self.q.put(("error", str(e)))

    def _choose(self, rows, row):
        rows = [r for r in rows if r.get("kind") == "20302" and complete_url(r.get("raw_url"))]
        if not rows:
            return None
        sec = int(row.get("seconds") or 0)
        scored = []
        for r in rows:
            m = r.get("meta") or {}
            dl = m.get("vid_len")
            if sec and dl is not None:
                try:
                    diff = abs(int(dl) - sec)
                except Exception:
                    diff = 99999
            else:
                diff = 99999
            scored.append((diff, r))
        scored.sort(key=lambda x: x[0])
        if len(scored) == 1:
            return scored[0][1]
        if scored[0][0] <= 3:
            # 唯一时长命中才接受；多个相同分数视为歧义
            same = [r for d, r in scored if d == scored[0][0]]
            if len(same) == 1:
                return same[0]
        return None

    def _download(self, url, oid, row):
        tag = "".join(ch for ch in oid if ch.isalnum()) or "slot"
        sec = int(row.get("seconds") or 0)
        args = [
            "pwsh.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", TOOL, "-SaveUrl", url, "-SaveTag", tag,
            "-OutDir", OUT_DIR,
        ]
        if sec > 0:
            args += ["-ExpectedDuration", str(sec)]
        try:
            p = subprocess.run(args, capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=600)
            out = (p.stdout or "") + "\n" + (p.stderr or "")
            for line in out.splitlines():
                if line.startswith("SAVED="):
                    return line.split("=", 1)[1].strip(), ""
            reason = ""
            for line in reversed(out.splitlines()):
                if line.strip():
                    reason = line.strip()
                    break
            return "", (reason or "FAILED")
        except Exception as e:
            return "", str(e)


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("视频号卡片 / 下载")
        self.geometry("1160x720")
        self.q = queue.Queue()
        self.lib = load_lib()
        self.cards = []
        self.photos = []
        self.page = 0
        self.page_size = 20
        self.worker = None
        self.scanner = None
        self._build()
        self.after(400, self.start_scan)
        self.after(200, self.poll)

    def _build(self):
        bar = tk.Frame(self)
        bar.pack(fill="x", padx=8, pady=6)
        self.scan_btn = ttk.Button(bar, text="重新扫描", command=self.start_scan)
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
                                 columns=("seq", "dur", "like", "status", "desc"))
        self.tree.heading("#0", text="封面")
        self.tree.column("#0", width=72, anchor="center")
        for c, t, w in (("seq", "序号", 55), ("dur", "时长", 70),
                        ("like", "点赞", 70), ("status", "状态", 90),
                        ("desc", "文案", 760)):
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w, anchor="w")
        self.tree.pack(fill="both", expand=True, padx=8, pady=4)
        self.tree.bind("<Double-1>", lambda e: self.download_selected())

        self.log = tk.Text(self, height=7, state="disabled")
        self.log.pack(fill="x", padx=8, pady=(0, 8))

    def logline(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def start_scan(self):
        if self.worker and self.worker.is_alive():
            return
        self.scan_btn.configure(state="disabled")
        self.dl_btn.configure(state="disabled")
        self.status.configure(text="采集中…")
        self.withdraw()  # 避免窗口遮住微信卡片，影响封面截图
        self.scanner = ScanWorker(self.q)
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
                    self.status.configure(
                        text=f"第 {step['page']} 页 · 已发现 {step['unique']} · 新增 {step['new']}")
                elif kind == "done":
                    self.on_scan_done(item[1])
                elif kind == "error":
                    self.deiconify()
                    self.status.configure(text="失败: " + item[1])
                    self.logline("ERROR " + item[1])
                    self.scan_btn.configure(state="normal")
                    self.dl_btn.configure(state="normal")
                elif kind == "status":
                    self.status.configure(text=item[1])
                    self.logline(item[1])
                elif kind == "bound":
                    d = item[1]
                    row = self.selected()
                    if row:
                        row["object_id"] = d["object_id"]
                        row["url"] = d["url"]
                        self.lib[row["key"]] = row
                        save_lib(self.lib)
                    self.logline(f"bound oid={d['object_id']} invoke={d['invoke']}")
                elif kind == "saved":
                    d = item[1]
                    row = self.selected()
                    if row:
                        row["file"] = d["file"]
                        row["status"] = "done"
                        row["object_id"] = d["object_id"]
                        row["url"] = d["url"]
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
                    row = self.selected()
                    if row:
                        row["status"] = "failed"
                        row["error"] = item[1]
                        self.lib[row["key"]] = row
                        save_lib(self.lib)
                    self.status.configure(text="失败: " + item[1])
                    self.logline("FAILED " + item[1])
                    self.scan_btn.configure(state="normal")
                    self.dl_btn.configure(state="normal")
        except queue.Empty:
            pass
        self.after(150, self.poll)

    def on_scan_done(self, snap):
        self.deiconify()
        self.cards = snap.get("cards", [])
        # 合并已下载/已绑定的状态
        for c in self.cards:
            old = self.lib.get(c["key"], {})
            for k in ("object_id", "url", "file", "status", "error"):
                if old.get(k):
                    c[k] = old[k]
            if c.get("file") and os.path.exists(c["file"]):
                c["status"] = "done"
            elif c.get("url"):
                c["status"] = c.get("status") or "ready"
            else:
                c["status"] = c.get("status") or "pending"
        self.account.configure(text="账号: " + (snap.get("account") or "-"))
        self.status.configure(
            text=f"完成 · {snap.get('discovered',0)} 张 · {snap.get('total_text','')}")
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
                (c.get("desc") or "")[:110]))

    def prev_page(self):
        if self.page > 0:
            self.page -= 1
            self.render()

    def next_page(self):
        total = max(1, (len(self.cards) + self.page_size - 1) // self.page_size)
        if self.page + 1 < total:
            self.page += 1
            self.render()

    def selected(self):
        items = self.tree.selection()
        if not items:
            return None
        i = self.page * self.page_size + self.tree.index(items[0])
        return self.cards[i] if 0 <= i < len(self.cards) else None

    def download_selected(self):
        row = self.selected()
        if not row:
            messagebox.showinfo("提示", "先选中一行")
            return
        if row.get("file") and os.path.exists(row["file"]):
            os.startfile(os.path.dirname(row["file"]))
            return
        if self.worker and self.worker.is_alive():
            return
        self.dl_btn.configure(state="disabled")
        self.status.configure(text="激活卡片…")
        self.worker = ActivateWorker(self.q, dict(row))
        self.worker.start()


if __name__ == "__main__":
    os.makedirs(WORK, exist_ok=True)
    App().mainloop()
