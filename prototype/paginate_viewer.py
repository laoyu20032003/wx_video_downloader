# -*- coding: utf-8 -*-
"""最小可用的滚动分页查看器（Tkinter，不依赖 PyQt）。

启动后自动在微信作者主页里滚动，表格会随采集增量刷新。
这是验证分页链路的原型；正式 viewer 可以复用 uia_paginate.Collector。
"""
import os
import queue
import sys
import threading
import tkinter as tk
from tkinter import ttk, messagebox
from PIL import Image, ImageTk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from uia_paginate import Collector

WORK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work")
OUT = os.path.join(WORK, "uia_paginated.json")


class Worker(threading.Thread):
    def __init__(self, q, collector):
        super().__init__(daemon=True)
        self.q = q
        self.collector = collector

    def run(self):
        try:
            def on_step(step, snap):
                self.q.put(("step", step, snap))
            snap = self.collector.run(on_step)
            self.q.put(("done", snap))
        except Exception as e:
            self.q.put(("error", str(e)))


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("UIA 滚动分页测试")
        self.geometry("980x640")
        self.q = queue.Queue()
        self.worker = None
        self.collector = None
        self.photos = []
        self._build()
        self.after(600, self.start)
        self.after(200, self.poll)

    def _build(self):
        bar = tk.Frame(self)
        bar.pack(fill="x", padx=8, pady=6)
        self.start_btn = ttk.Button(bar, text="重新采集", command=self.start)
        self.stop_btn = ttk.Button(bar, text="停止", command=self.stop, state="disabled")
        self.status = ttk.Label(bar, text="准备")
        self.start_btn.pack(side="left")
        self.stop_btn.pack(side="left", padx=6)
        self.status.pack(side="left", padx=10)

        cols = ("seq", "page", "dur", "like", "desc")
        style = ttk.Style(self)
        style.configure("Treeview", rowheight=96)
        self.tree = ttk.Treeview(self, columns=cols, show="tree headings")
        self.tree.heading("#0", text="封面")
        self.tree.column("#0", width=72, anchor="center")
        for c, t, w in (
            ("seq", "序号", 60), ("page", "页", 50), ("dur", "时长", 80),
            ("like", "点赞", 80), ("desc", "文案", 650)):
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w, anchor="w")
        self.tree.pack(fill="both", expand=True, padx=8, pady=4)

        self.footer = ttk.Label(self, text="")
        self.footer.pack(fill="x", padx=8, pady=4)

    def start(self):
        if self.worker and self.worker.is_alive():
            return
        self.start_btn.configure(state="disabled")
        self.stop_btn.configure(state="normal")
        self.status.configure(text="采集中…（会自动滚动微信）")
        self.tree.delete(*self.tree.get_children())
        self.collector = Collector(OUT, wait=0.75, max_pages=45, scroll=True, restore=True, cap=False)
        self.worker = Worker(self.q, self.collector)
        self.worker.start()

    def stop(self):
        if self.collector:
            self.collector.stop_flag = True
        self.status.configure(text="停止中…")

    def poll(self):
        try:
            while True:
                item = self.q.get_nowait()
                if item[0] == "step":
                    _, step, snap = item
                    self.render(snap)
                    self.status.configure(
                        text=f"第 {step['page']} 页 · 树内 {step['tree']} · 已发现 {step['unique']} · 新增 {step['new']}")
                elif item[0] == "done":
                    snap = item[1]
                    self.render(snap)
                    self.status.configure(
                        text=f"完成 · 发现 {snap['discovered']} · {snap.get('elapsed','?')}s")
                    self.start_btn.configure(state="normal")
                    self.stop_btn.configure(state="disabled")
                    self.footer.configure(
                        text=f"账号 {snap.get('account','?')} · {snap.get('total_text','')} · 输出 {OUT}")
                elif item[0] == "error":
                    self.status.configure(text="失败：" + item[1])
                    self.start_btn.configure(state="normal")
                    self.stop_btn.configure(state="disabled")
                    messagebox.showerror("采集失败", item[1])
        except queue.Empty:
            pass
        self.after(150, self.poll)

    def render(self, snap):
        self.tree.delete(*self.tree.get_children())
        self.photos = []
        for c in snap["cards"]:
            photo = None
            path = c.get("cover_path") or ""
            if path and os.path.exists(path):
                try:
                    img = Image.open(path)
                    img.thumbnail((64, 90))
                    photo = ImageTk.PhotoImage(img)
                    self.photos.append(photo)
                except Exception:
                    photo = None
            self.tree.insert("", "end", image=photo, values=(
                c.get("index", ""), c.get("page", ""), c.get("duration", ""),
                c.get("like", ""), (c.get("desc") or "")[:100]))
        self.footer.configure(
            text=f"账号 {snap.get('account','?')} · {snap.get('total_text','')} · 已发现 {snap.get('discovered',0)}")


if __name__ == "__main__":
    os.makedirs(WORK, exist_ok=True)
    App().mainloop()
