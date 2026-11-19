# -*- coding: utf-8 -*-
"""UIA 滚动分页采集器（原型，可复制到 tools/uia-collect.py 的位置）。

特点：
  - 只读 UIA，不点击卡片；
  - 读取活动 page-profile 内所有 click-box，不按视口裁剪；
  - 用鼠标滚轮翻页（微信 page-profile 没有 ScrollPattern）；
  - 按 时长+点赞+文案 指纹合并，输出增量卡片表；
  - 结束时滚回顶部（可用 --no-restore 关闭）。

用法：
  python uia_paginate.py
  python uia_paginate.py --max-pages 15 --wait 0.8 --out work/uia_paginated.json
  python uia_paginate.py --no-scroll       # 只读当前批次，不滚屏
"""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
import re
import sys
import time

import comtypes
import comtypes.client
import comtypes.gen.UIAutomationClient as U

DUR_RE = re.compile(r"^\d{1,2}:\d{2}(:\d{2})?$")
LIKE_RE = re.compile(r"^\d+(\.\d+)?[万wW]?$")
TOTAL_RE = re.compile(r"(\d+)\s*条原创内容")
USER32 = ctypes.WinDLL("user32", use_last_error=True)


def wechat_pids():
    try:
        import psutil
        out = set()
        for p in psutil.process_iter(["pid", "name"]):
            n = (p.info["name"] or "").lower()
            if n in ("weixin.exe", "wechatappex.exe"):
                out.add(p.info["pid"])
        return out
    except Exception:
        return set()


def duration_seconds(s):
    try:
        parts = [int(x) for x in str(s).split(":")]
    except Exception:
        return 0
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    return 0


def parse_like(s):
    if not s:
        return None
    m = re.match(r"^(\d+(?:\.\d+)?)万", s)
    if m:
        return int(float(m.group(1)) * 10000)
    m = re.match(r"^(\d+)", s)
    return int(m.group(1)) if m else None


class Collector:
    def __init__(self, out_path, wait=0.8, max_pages=12, scroll=True, restore=True, cap=False, capture_covers=True):
        self.out_path = out_path
        self.wait = wait
        self.max_pages = max_pages
        self.scroll = scroll
        self.restore = restore
        self.cap = cap
        self.capture_covers = capture_covers
        self.cover_dir = os.path.join(os.path.dirname(os.path.abspath(out_path)), "covers_uia")
        self.stop_flag = False
        self.cards = {}
        self.steps = []
        self.total_text = ""
        self.total_count = None
        self.account = ""
        self.last_find_reason = ""
        self.profile = None
        self.window = None
        self.hwnd = 0
        self.auto = None
        self.walker = None
        self.box_cond = None
        self.text_cond = None

    # ---- UIA setup -----------------------------------------------------
    def _init_uia(self):
        comtypes.CoInitialize()
        comtypes.client.GetModule("UIAutomationCore.dll")
        self.auto = comtypes.client.CreateObject(
            U.CUIAutomation._reg_clsid_, interface=U.IUIAutomation)
        self.walker = self.auto.CreateTreeWalker(self.auto.CreateTrueCondition())
        self.box_cond = self.auto.CreatePropertyCondition(
            U.UIA_ClassNamePropertyId, "click-box")
        self.text_cond = self.auto.CreatePropertyCondition(
            U.UIA_ControlTypePropertyId, U.UIA_TextControlTypeId)

    def _pick_profile(self):
        root = self.auto.GetRootElement()
        pids = wechat_pids()
        tops = root.FindAll(
            U.TreeScope_Children,
            self.auto.CreatePropertyCondition(
                U.UIA_ControlTypePropertyId, U.UIA_WindowControlTypeId))
        best = None
        for i in range(tops.Length):
            top = tops.GetElement(i)
            try:
                if int(top.CurrentProcessId) not in pids:
                    continue
                profiles = top.FindAll(
                    U.TreeScope_Descendants,
                    self.auto.CreatePropertyCondition(
                        U.UIA_ClassNamePropertyId, "page-profile"))
                for j in range(profiles.Length):
                    prof = profiles.GetElement(j)
                    try:
                        boxes = prof.FindAll(U.TreeScope_Descendants, self.box_cond)
                        if boxes.Length == 0:
                            continue
                        # 选卡片最多的 profile；多账号层时再按可见面积兜底
                        area = 0
                        try:
                            r = prof.CurrentBoundingRectangle
                            area = max(0, r.right - r.left) * max(0, r.bottom - r.top)
                        except Exception:
                            pass
                        score = (boxes.Length, area)
                        if best is None or score > best[0]:
                            best = (score, prof, top)
                    except Exception:
                        continue
            except Exception:
                continue
        if best is None:
            raise RuntimeError("没有找到视频号 page-profile")
        self.profile, self.window = best[1], best[2]
        try:
            self.hwnd = int(self.window.CurrentNativeWindowHandle)
        except Exception:
            self.hwnd = 0

    def _read_total(self):
        try:
            texts = self.profile.FindAll(U.TreeScope_Descendants, self.text_cond)
            for i in range(texts.Length):
                n = texts.GetElement(i).CurrentName or ""
                m = TOTAL_RE.search(n)
                if m:
                    self.total_text = n
                    # 注意：这是主页的“原创内容”计数，不是作品总数。
                    # 未声明原创、图片/图文、直播回放也会出现在主页作品流里，因此默认不拿它当截断上限。
                    self.total_count = int(m.group(1))
                    return
        except Exception:
            pass

    def _read_account(self):
        # 账号名通常在 header 中重复出现；取第一个短文本作为展示名即可
        try:
            texts = self.profile.FindAll(U.TreeScope_Descendants, self.text_cond)
            names = []
            for i in range(texts.Length):
                n = (texts.GetElement(i).CurrentName or "").strip()
                if n and len(n) <= 24:
                    names.append(n)
            for n in names:
                if names.count(n) >= 2:
                    self.account = n
                    return
            if names:
                self.account = names[0]
        except Exception:
            pass

    # ---- card read -----------------------------------------------------
    def read_cards(self, viewport_only=True):
        boxes = self.profile.FindAll(U.TreeScope_Descendants, self.box_cond)
        try:
            pr = self.profile.CurrentBoundingRectangle
            vx, vy, vr, vb = pr.left, pr.top, pr.right, pr.bottom
        except Exception:
            viewport_only = False
            vx = vy = vr = vb = 0
        out = []
        for i in range(boxes.Length):
            box = boxes.GetElement(i)
            try:
                r = box.CurrentBoundingRectangle
            except Exception:
                continue
            w, h = r.right - r.left, r.bottom - r.top
            if w < 80 or h < 120:
                continue
            if viewport_only:
                ix, iy = max(r.left, vx), max(r.top, vy)
                ax, ay = min(r.right, vr), min(r.bottom, vb)
                if ax - ix < 40 or ay - iy < 60:
                    continue
            texts = []
            cover = (r.left, r.top, r.right, r.bottom)
            try:
                kids = box.FindAll(U.TreeScope_Descendants, self.auto.CreateTrueCondition())
                for j in range(kids.Length):
                    ch = kids.GetElement(j)
                    try:
                        ct = ch.CurrentControlType
                        name = ch.CurrentName or ""
                        if ct == U.UIA_ImageControlTypeId and name == "封面":
                            cr = ch.CurrentBoundingRectangle
                            cover = (cr.left, cr.top, cr.right, cr.bottom)
                            continue
                        if ct == U.UIA_TextControlTypeId and name:
                            texts.append(name)
                    except Exception:
                        continue
            except Exception:
                pass
            dur = ""
            like = ""
            desc = ""
            for t in texts:
                if DUR_RE.match(t):
                    dur = t
                elif LIKE_RE.match(t) and not like:
                    like = t
                elif len(t) > len(desc):
                    desc = t
            if not dur:
                continue
            key = f"{dur}|{like}|{desc}"
            out.append({
                "key": key,
                "rect": [int(r.left), int(r.top), int(r.right), int(r.bottom)],
                "cover": [int(cover[0]), int(cover[1]), int(cover[2]), int(cover[3])],
                "duration": dur,
                "seconds": duration_seconds(dur),
                "like": like,
                "like_int": parse_like(like),
                "desc": desc,
            })
        # 同一批里可能有重复/隐藏节点，按 key 去重
        uniq = {}
        for c in out:
            uniq.setdefault(c["key"], c)
        return list(uniq.values())

    def read_elements(self, viewport_only=False):
        """Read cards plus their live UIA elements (for activation)."""
        boxes = self.profile.FindAll(U.TreeScope_Descendants, self.box_cond)
        try:
            pr = self.profile.CurrentBoundingRectangle
            vx, vy, vr, vb = pr.left, pr.top, pr.right, pr.bottom
        except Exception:
            viewport_only = False
            vx = vy = vr = vb = 0
        out = []
        for i in range(boxes.Length):
            box = boxes.GetElement(i)
            try:
                r = box.CurrentBoundingRectangle
            except Exception:
                continue
            w, h = r.right - r.left, r.bottom - r.top
            if w < 80 or h < 120:
                continue
            if viewport_only:
                ix, iy = max(r.left, vx), max(r.top, vy)
                ax, ay = min(r.right, vr), min(r.bottom, vb)
                if ax - ix < 40 or ay - iy < 60:
                    continue
            texts = []
            cover = (r.left, r.top, r.right, r.bottom)
            try:
                kids = box.FindAll(U.TreeScope_Descendants, self.auto.CreateTrueCondition())
                for j in range(kids.Length):
                    ch = kids.GetElement(j)
                    try:
                        ct = ch.CurrentControlType
                        name = ch.CurrentName or ""
                        if ct == U.UIA_ImageControlTypeId and name == "封面":
                            cr = ch.CurrentBoundingRectangle
                            cover = (cr.left, cr.top, cr.right, cr.bottom)
                            continue
                        if ct == U.UIA_TextControlTypeId and name:
                            texts.append(name)
                    except Exception:
                        continue
            except Exception:
                pass
            dur = like = desc = ""
            for tx in texts:
                if DUR_RE.match(tx):
                    dur = tx
                elif LIKE_RE.match(tx) and not like:
                    like = tx
                elif len(tx) > len(desc):
                    desc = tx
            if not dur:
                continue
            out.append({
                "el": box,
                "key": f"{dur}|{like}|{desc}",
                "rect": [int(r.left), int(r.top), int(r.right), int(r.bottom)],
                "cover": [int(cover[0]), int(cover[1]), int(cover[2]), int(cover[3])],
                "duration": dur, "seconds": duration_seconds(dur),
                "like": like, "like_int": parse_like(like), "desc": desc,
            })
        return out

    def _visible(self, rect):
        try:
            pr = self.profile.CurrentBoundingRectangle
            ix, iy = max(rect[0], pr.left), max(rect[1], pr.top)
            ax, ay = min(rect[2], pr.right), min(rect[3], pr.bottom)
            return ax - ix >= 40 and ay - iy >= 60
        except Exception:
            return False

    def _card_from_box(self, box):
        try:
            r = box.CurrentBoundingRectangle
            if r.right - r.left < 80 or r.bottom - r.top < 120:
                return None
            texts = []
            cover = (r.left, r.top, r.right, r.bottom)
            kids = box.FindAll(U.TreeScope_Descendants, self.auto.CreateTrueCondition())
            for j in range(kids.Length):
                ch = kids.GetElement(j)
                try:
                    ct = ch.CurrentControlType
                    name = ch.CurrentName or ""
                    if ct == U.UIA_ImageControlTypeId and name == "封面":
                        cr = ch.CurrentBoundingRectangle
                        cover = (cr.left, cr.top, cr.right, cr.bottom)
                        continue
                    if ct == U.UIA_TextControlTypeId and name:
                        texts.append(name)
                except Exception:
                    continue
            dur = like = desc = ""
            for tx in texts:
                if DUR_RE.match(tx):
                    dur = tx
                elif LIKE_RE.match(tx) and not like:
                    like = tx
                elif len(tx) > len(desc):
                    desc = tx
            if not dur:
                return None
            return {
                "el": box,
                "key": f"{dur}|{like}|{desc}",
                "rect": [int(r.left), int(r.top), int(r.right), int(r.bottom)],
                "cover": [int(cover[0]), int(cover[1]), int(cover[2]), int(cover[3])],
                "duration": dur, "seconds": duration_seconds(dur),
                "like": like, "like_int": parse_like(like), "desc": desc,
            }
        except Exception:
            return None

    def _grid_boxes(self):
        win_cond = self.auto.CreatePropertyCondition(U.UIA_ControlTypePropertyId, U.UIA_WindowControlTypeId)
        tops = self.auto.GetRootElement().FindAll(U.TreeScope_Children, win_cond)
        best = None
        for i in range(tops.Length):
            top = tops.GetElement(i)
            try:
                boxes = top.FindAll(U.TreeScope_Descendants, self.box_cond)
            except Exception:
                continue
            if boxes.Length and (best is None or boxes.Length > best[1].Length):
                best = (top, boxes)
        if best is None:
            raise RuntimeError("未找到视频号卡片网格")
        top, boxes = best
        return top, boxes, top.CurrentBoundingRectangle

    def _scroll_pattern(self, top, boxes, wr):
        anchor = None
        for i in range(boxes.Length):
            r = boxes.GetElement(i).CurrentBoundingRectangle
            if r.top >= wr.top and r.bottom <= wr.bottom:
                anchor = boxes.GetElement(i)
                break
        if anchor is None:
            anchor = boxes.GetElement(0)
        cur = anchor
        for _ in range(8):
            if (cur.CurrentClassName or "") == "content":
                pat = cur.GetCurrentPattern(U.UIA_ScrollPatternId)
                return pat.QueryInterface(U.IUIAutomationScrollPattern)
            cur = self.walker.GetParentElement(cur)
            if cur is None:
                break
        return None

    def scroll_to_key(self, key, max_steps=60):
        """Pure-UIA ScrollPattern path: exact-key card -> ScrollIntoView."""
        self.last_find_reason = ""
        try:
            top, boxes, wr = self._grid_boxes()
        except Exception as e:
            self.last_find_reason = "没有卡片网格: " + str(e)
            return None
        target = None
        for i in range(boxes.Length):
            c = self._card_from_box(boxes.GetElement(i))
            if c and c["key"] == key:
                if target is not None:
                    self.last_find_reason = "网格中存在多个完全同 key 候选"
                    return None
                target = i
        if target is None:
            self.last_find_reason = "卡片网格中没有完全同 key 的 click-box"
            return None
        try:
            sp = self._scroll_pattern(top, boxes, wr)
        except Exception as e:
            self.last_find_reason = "获取 ScrollPattern 失败: " + str(e)
            return None
        if sp is None:
            self.last_find_reason = "content 没有暴露 ScrollPattern"
            return None

        prev_pct = None
        stall = 0
        for step in range(max_steps):
            visible = []
            for i in range(boxes.Length):
                r = boxes.GetElement(i).CurrentBoundingRectangle
                ix = max(r.left, wr.left)
                iy = max(r.top, wr.top)
                ax = min(r.right, wr.right)
                ay = min(r.bottom, wr.bottom)
                if ax - ix >= 40 and ay - iy >= 60:
                    visible.append(i)
            if target in visible:
                try:
                    el = boxes.GetElement(target)
                    el.GetCurrentPattern(U.UIA_ScrollItemPatternId).QueryInterface(
                        U.IUIAutomationScrollItemPattern).ScrollIntoView()
                except Exception:
                    pass
                time.sleep(0.25)
                box = boxes.GetElement(target)
                card = self._card_from_box(box)
                if card and self._visible(card["rect"]):
                    return card
            try:
                pct = sp.CurrentVerticalScrollPercent
            except Exception:
                pct = -1
            if prev_pct is not None and abs(pct - prev_pct) < 1e-6:
                stall += 1
            else:
                stall = 0
            prev_pct = pct
            if stall >= 3:
                self.last_find_reason = f"滚动到边界但目标仍在视口外（target={target}）"
                return None
            try:
                if visible and target < visible[0]:
                    sp.Scroll(U.ScrollAmount_NoAmount, U.ScrollAmount_LargeDecrement)
                else:
                    sp.Scroll(U.ScrollAmount_NoAmount, U.ScrollAmount_LargeIncrement)
            except Exception as e:
                self.last_find_reason = "ScrollPattern 滚动失败: " + str(e)
                return None
            time.sleep(0.35)
        self.last_find_reason = f"超过 {max_steps} 步仍未把目标滚入视口"
        return None

    def find_card(self, key, tries=8):
        """Fast path: native UIA Name search, then climb to the click-box.

        The old read_elements() path enumerates 2000+ cards and takes ~20s.
        FindAll(Name=desc) is handled inside the UIA provider and takes <1s.
        """
        self.last_find_reason = ""
        if self.profile is None:
            self._init_uia()
            self._pick_profile()
        # 首选：content ScrollPattern 精确滚到目标，不模拟鼠标/键盘
        try:
            card = self.scroll_to_key(key)
            if card:
                return card
        except Exception as e:
            self.last_find_reason = "ScrollPattern 定位异常: " + str(e)
        parts = key.split("|", 2)
        desc = parts[2] if len(parts) >= 3 else ""
        if desc:
            for _ in range(tries):
                try:
                    cond = self.auto.CreatePropertyCondition(U.UIA_NamePropertyId, desc)
                    hits = self.profile.FindAll(U.TreeScope_Descendants, cond)
                except Exception:
                    hits = None
                cards = []
                if hits is not None:
                    for i in range(hits.Length):
                        cur = hits.GetElement(i)
                        for _up in range(6):
                            try:
                                if cur.CurrentClassName == "click-box":
                                    card = self._card_from_box(cur)
                                    if card:
                                        cards.append(card)
                                    break
                                cur = self.walker.GetParentElement(cur)
                            except Exception:
                                break
                # Deduplicate by key
                cards = [c for c in cards if c["key"] == key]
                if len(cards) == 1:
                    card = cards[0]
                    if self._visible(card["rect"]):
                        return card
                    try:
                        pr = self.profile.CurrentBoundingRectangle
                        self._wheel(False if card["rect"][1] < pr.top else True)
                        time.sleep(0.4)
                    except Exception:
                        pass
                    continue
                if len(cards) > 1:
                    self.last_find_reason = f"同 key 候选 {len(cards)} 个，拒绝猜"
                    return None
                break
        return self._find_card_full(key, tries=tries)
    def _find_card_full(self, key, tries=18):
        """Re-resolve a slot key against the live UIA grid, scrolling if needed."""
        if self.profile is None:
            self._init_uia()
            self._pick_profile()
        self._focus()
        for _ in range(tries):
            cards = self.read_elements(False)
            matches = [c for c in cards if c["key"] == key]
            if not matches:
                self.last_find_reason = "当前 UIA 没有完全相同的 duration|like|desc"
                return None
            if len(matches) > 1:
                self.last_find_reason = f"完全同 key 候选 {len(matches)} 个，拒绝猜"
                return None
            card = matches[0]
            if self._visible(card["rect"]):
                return card
            try:
                pr = self.profile.CurrentBoundingRectangle
                if card["rect"][1] < pr.top:
                    self._wheel(False)
                else:
                    self._wheel(True)
            except Exception:
                self._wheel(True)
            time.sleep(0.45)
        self.last_find_reason = "找到候选但滚不到视口（UIA 滚屏可能被隔离）"
        return None

    def diagnose(self, key):
        """Explain why a slot could not be found; read-only and best-effort."""
        parts = key.split("|", 2)
        dur = parts[0] if parts else ""
        like = parts[1] if len(parts) > 1 else ""
        desc = parts[2] if len(parts) > 2 else ""
        try:
            if not getattr(self, "account", ""):
                self._read_account()
            cards = self.read_elements(False)
        except Exception as e:
            return {"error": str(e), "cards": 0, "visible": 0}
        visible = [c for c in cards if self._visible(c["rect"])]
        same_dur = [c for c in cards if c["duration"] == dur]
        same_dl = [c for c in same_dur if c["like"] == like]
        same_desc = [c for c in same_dur if (c.get("desc") or "") == desc]
        top = (same_desc or same_dl or same_dur)[:3]
        return {
            "cards": len(cards),
            "visible": len(visible),
            "same_duration": len(same_dur),
            "same_duration_like": len(same_dl),
            "same_desc": len(same_desc),
            "account": getattr(self, "account", "") or "",
            "examples": [
                f'{c["duration"]}|{c["like"]}|{(c.get("desc") or "")[:24]}'
                for c in top
            ],
        }

    def hover(self, card, seconds=2.2):
        self._focus()
        r = card["cover"]
        USER32.SetCursorPos(int((r[0] + r[2]) / 2), int((r[1] + r[3]) / 2))
        time.sleep(seconds)

    def invoke(self, card):
        try:
            pat = card["el"].GetCurrentPattern(U.UIA_InvokePatternId)
            if not pat:
                return False
            inv = pat.QueryInterface(U.IUIAutomationInvokePattern)
            inv.Invoke()
            return True
        except Exception:
            return False

    def click(self, card):
        self._focus()
        r = card["cover"]
        x, y = int((r[0] + r[2]) / 2), int((r[1] + r[3]) / 2)
        USER32.SetCursorPos(x, y)
        USER32.mouse_event(0x0002, 0, 0, 0, 0)
        time.sleep(0.05)
        USER32.mouse_event(0x0004, 0, 0, 0, 0)

    def close_player(self):
        # 播放器/详情一般可以用 Esc 返回
        try:
            USER32.keybd_event(0x1B, 0, 0, 0)
            time.sleep(0.05)
            USER32.keybd_event(0x1B, 0, 2, 0)
            time.sleep(0.4)
        except Exception:
            pass
    # ---- scroll --------------------------------------------------------
    def _scroll_point(self):
        try:
            r = self.profile.CurrentBoundingRectangle
            return (int((r.left + r.right) / 2), int((r.top + r.bottom) / 2))
        except Exception:
            return (900, 500)

    def _focus(self):
        if self.hwnd:
            try:
                USER32.ShowWindow(ctypes.c_void_p(self.hwnd), 9)
                USER32.keybd_event(0x12, 0, 0, 0)  # Alt，绕过部分前台锁
                USER32.SetForegroundWindow(ctypes.c_void_p(self.hwnd))
                USER32.keybd_event(0x12, 0, 2, 0)
            except Exception:
                pass
        x, y = self._scroll_point()
        USER32.SetCursorPos(x, y)
        time.sleep(0.25)

    def _reset_top(self, steps=30):
        self._focus()
        for _ in range(steps):
            self._wheel(False)
            time.sleep(0.03)
        time.sleep(0.3)

    def _wheel(self, down=True):
        delta = -900 if down else 900
        USER32.mouse_event(0x0800, 0, 0, delta, 0)

    def _capture_cover(self, card):
        if not self.capture_covers:
            return ""
        try:
            from PIL import ImageGrab
            r = card.get("cover") or card.get("rect")
            left, top, right, bottom = [int(x) for x in r]
            sw = USER32.GetSystemMetrics(0)
            sh = USER32.GetSystemMetrics(1)
            try:
                pr = self.profile.CurrentBoundingRectangle
                left = max(left, int(pr.left))
                top = max(top, int(pr.top))
                right = min(right, int(pr.right))
                bottom = min(bottom, int(pr.bottom))
            except Exception:
                pass
            left, top = max(0, left), max(0, top)
            right, bottom = min(sw, right), min(sh, bottom)
            if right - left < 40 or bottom - top < 60:
                return ""
            os.makedirs(self.cover_dir, exist_ok=True)
            name = hashlib.md5(card["key"].encode("utf-8", "ignore")).hexdigest() + ".jpg"
            path = os.path.join(self.cover_dir, name)
            if os.path.exists(path):
                return path
            img = ImageGrab.grab(bbox=(left, top, right, bottom), all_screens=True)
            img.save(path, "JPEG", quality=85)
            return path
        except Exception as e:
            self.cover_error = str(e)
            return ""
    def _merge(self, cards, page):
        new = 0
        now = datetime.datetime.now().isoformat(timespec="seconds")
        for c in cards:
            key = c["key"]
            if key not in self.cards:
                c["page"] = page + 1
                c["cover_path"] = self._capture_cover(c)
                c["first_seen"] = now
                self.cards[key] = c
                new += 1
            else:
                self.cards[key]["last_seen"] = now
                self.cards[key]["last_page"] = page
        return new

    # ---- public --------------------------------------------------------
    def run(self, on_step=None):
        self._init_uia()
        self._pick_profile()
        self._read_total()
        self._read_account()
        if self.scroll:
            self._reset_top()

        no_new = 0
        pages = 0
        start = time.time()
        for page in range(self.max_pages):
            if self.stop_flag:
                break
            pages = page + 1
            cards = self.read_cards()
            new = self._merge(cards, page)
            no_new = no_new + 1 if new == 0 else 0
            step = {
                "page": page + 1,
                "tree": len(cards),
                "unique": len(self.cards),
                "new": new,
                "min_y": min([c["rect"][1] for c in cards], default=0),
                "max_y": max([c["rect"][1] for c in cards], default=0),
            }
            self.steps.append(step)
            if on_step:
                on_step(step, self.snapshot())
            if self.cap and self.total_count and len(self.cards) >= self.total_count:
                # 到达原创总数即停；继续滚会进入推荐流/历史缓存
                break
            if no_new >= 2:
                break
            if not self.scroll:
                break
            if page + 1 < self.max_pages:
                self._wheel(True)
                time.sleep(self.wait)

        # 回顶部（恢复用户位置）
        if self.scroll and self.restore and pages > 1:
            self._focus()
            for _ in range(pages - 1):
                self._wheel(False)
                time.sleep(0.08)

        snap = self.snapshot()
        snap["elapsed"] = round(time.time() - start, 1)
        self._save(snap)
        return snap

    def snapshot(self):
        cards = sorted(self.cards.values(),
                       key=lambda c: (c.get("page", 0), c["rect"][1], c["rect"][0]))
        truncated = bool(self.cap and self.total_count and len(cards) > self.total_count)
        if truncated:
            cards = cards[:self.total_count]
        for i, c in enumerate(cards):
            c["index"] = i
        return {
            "captured": datetime.datetime.now().isoformat(timespec="seconds"),
            "account": self.account,
            "total_text": self.total_text,
            "total_count": self.total_count,
            "pages": len(self.steps),
            "discovered": len(cards),
            "truncated": truncated,
            "steps": self.steps,
            "cards": cards,
        }

    def _save(self, snap):
        os.makedirs(os.path.dirname(os.path.abspath(self.out_path)), exist_ok=True)
        with open(self.out_path, "w", encoding="utf-8") as f:
            json.dump(snap, f, ensure_ascii=False, indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "work", "uia_paginated.json"))
    ap.add_argument("--wait", type=float, default=0.8)
    ap.add_argument("--max-pages", type=int, default=12)
    ap.add_argument("--no-scroll", action="store_true")
    ap.add_argument("--no-restore", action="store_true")
    ap.add_argument("--cap", action="store_true")
    ap.add_argument("--no-covers", action="store_true")
    a = ap.parse_args()
    col = Collector(a.out, wait=a.wait, max_pages=a.max_pages,
                    scroll=not a.no_scroll, restore=not a.no_restore, cap=a.cap, capture_covers=not a.no_covers)

    def on_step(step, snap):
        print("page={page} tree={tree} unique={unique} new={new} y={min_y}..{max_y}".format(**step))

    snap = col.run(on_step)
    print(f"account={snap['account']} total={snap['total_text']} discovered={snap['discovered']} -> {a.out}")


if __name__ == "__main__":
    main()
