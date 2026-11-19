# -*- coding: utf-8 -*-
"""程序化触发取流：PostMessage 直投 cards 网格窗对应卡片，右键→「播放」起播。

不移动全局光标、不发 SendInput；前台可见 / 遮挡失焦 / 被同宿主播放窗盖住三档均实测可行
（见 docs/player-flow-architecture.md §8.5）。最小化不可见档投递不到。

匹配方式（优先序）：
  --index N                 按网格顺序号（与 uia_cards.json 同序）
  --desc 前缀 --seconds S --like L   指纹匹配（时长 + 点赞 + 文案前缀）

用法：
  python tools/trigger_feed.py --index 3
  python tools/trigger_feed.py --desc "你有给舞队" --seconds 46 --like 152
输出 JSON 到 stdout：{ok, reason, hwnd, card_index, rect, menu, played}
"""
import argparse, ctypes, ctypes.wintypes as wt, json, os, re, sys, time
import psutil
import comtypes.client
import comtypes.gen.UIAutomationClient as U

WM_MOVE, WM_LDOWN, WM_LUP = 0x0200, 0x0201, 0x0202
WM_RDOWN, WM_RUP = 0x0204, 0x0205
MK_L, MK_R = 0x0001, 0x0002
DUR_RE = re.compile(r"^\d{1,2}:\d{2}(:\d{2})?$")
LIKE_RE = re.compile(r"^\d+(\.\d+)?[万wW]?$")

u = ctypes.windll.user32


def app_pids():
    out = set()
    for p in psutil.process_iter(["pid", "name"]):
        if (p.info["name"] or "").lower() in ("weixin.exe", "wechatappex.exe"):
            out.add(p.info["pid"])
    return out


def conv_dur(s):
    parts = (s or "").split(":")
    try:
        parts = [int(x) for x in parts]
    except ValueError:
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


def lp(x, y):
    return (y << 16) | (x & 0xFFFF)


def to_client(hwnd, sx, sy):
    pt = wt.POINT(sx, sy)
    u.ScreenToClient(hwnd, ctypes.byref(pt))
    return pt.x, pt.y


def find_cards(auto, root):
    """枚举所有 webview 顶层窗下的网格卡片，返回 [{el, hwnd, rect, seconds, like_int, desc, index}]。"""
    pids = app_pids()
    box_cond = auto.CreatePropertyCondition(U.UIA_ClassNamePropertyId, "click-box")
    tops = root.FindAll(U.TreeScope_Children, auto.CreatePropertyCondition(
        U.UIA_ControlTypePropertyId, U.UIA_WindowControlTypeId))
    cards = []
    for i in range(tops.Length):
        top = tops.GetElement(i)
        try:
            if int(top.CurrentProcessId) not in pids:
                continue
            hwnd = top.CurrentNativeWindowHandle
            boxes = top.FindAll(U.TreeScope_Descendants, box_cond)
            for j in range(boxes.Length):
                box = boxes.GetElement(j)
                cls = box.CurrentClassName or ""
                if "op-item" in cls or "more-btn" in cls:
                    continue
                r = box.CurrentBoundingRectangle
                if r.right - r.left < 80 or r.bottom - r.top < 120:
                    continue
                dur = desc = like = ""
                kids = box.FindAll(U.TreeScope_Descendants, auto.CreateTrueCondition())
                for k in range(kids.Length):
                    ch = kids.GetElement(k)
                    try:
                        ct = ch.CurrentControlType
                        name = ch.CurrentName or ""
                        if ct != U.UIA_TextControlTypeId:
                            continue
                        if DUR_RE.match(name):
                            dur = name
                        elif LIKE_RE.match(name):
                            like = name
                        elif len(name) > len(desc):
                            desc = name
                    except Exception:
                        continue
                if not dur:
                    continue
                cards.append({
                    "el": box, "hwnd": hwnd,
                    "rect": [r.left, r.top, r.right, r.bottom],
                    "seconds": conv_dur(dur), "like_int": parse_like(like),
                    "desc": desc,
                })
        except Exception:
            continue
    cards.sort(key=lambda c: ((c["rect"][1] + c["rect"][3]) // 60,
                              (c["rect"][0] + c["rect"][2]) // 2))
    for i, c in enumerate(cards):
        c["index"] = i
    return cards


def match(cards, args):
    if args.index is not None:
        for c in cards:
            if c["index"] == args.index:
                return c, "index"
        return None, f"index {args.index} 越界（共 {len(cards)} 张）"
    # 指纹：时长 + 点赞 + 文案前缀
    pref = (args.desc or "").strip()[:12]
    cand = []
    for c in cards:
        ok_sec = (args.seconds is None or c["seconds"] == args.seconds)
        ok_like = (args.like is None or c["like_int"] == args.like)
        ok_desc = (not pref or pref in (c["desc"] or ""))
        if ok_sec and ok_like and ok_desc:
            cand.append(c)
    if len(cand) == 1:
        return cand[0], "fingerprint"
    if len(cand) > 1:
        return None, f"指纹命中 {len(cand)} 张，歧义"
    return None, "指纹未命中卡片"


def post(hwnd, msg, wparam, x, y):
    u.PostMessageW(hwnd, msg, wparam, lp(x, y))


def win_rect(hwnd):
    r = wt.RECT()
    u.GetWindowRect(hwnd, ctypes.byref(r))
    return r.left, r.top, r.right, r.bottom


def find_menus(auto, root):
    out = []
    alln = root.FindAll(U.TreeScope_Descendants, auto.CreateTrueCondition())
    for i in range(alln.Length):
        try:
            if (alln.GetElement(i).CurrentClassName or "") == "context-menu":
                out.append(alln.GetElement(i))
        except Exception:
            continue
    return out


def menu_items(m, auto):
    items = m.FindAll(U.TreeScope_Descendants, auto.CreateTrueCondition())
    return [(items.GetElement(j).CurrentName or "").strip() for j in range(items.Length)]


def dismiss_residual(auto, root, hwnd):
    """右键前清掉上一轮残留的 context-menu（Esc PostMessage 关不掉，需外点空白），复查清零。"""
    for _ in range(3):
        if not find_menus(auto, root):
            return True
        l, t, r, b = win_rect(hwnd)
        sx, sy = r - 80, t + 60
        cx, cy = to_client(hwnd, sx, sy)
        post(hwnd, WM_MOVE, 0, cx, cy); time.sleep(0.05)
        post(hwnd, WM_LDOWN, MK_L, cx, cy); time.sleep(0.08)
        post(hwnd, WM_LUP, 0, cx, cy); time.sleep(0.4)
    return not find_menus(auto, root)


def _probe(auto, root, hwnd):
    """硬指标复核：该窗封面 prev-i 计数 / vjs-tech 计数。"""
    top = None
    tops = root.FindAll(U.TreeScope_Children, auto.CreatePropertyCondition(
        U.UIA_ControlTypePropertyId, U.UIA_WindowControlTypeId))
    for i in range(tops.Length):
        t = tops.GetElement(i)
        try:
            if t.CurrentNativeWindowHandle == hwnd:
                top = t; break
        except Exception:
            continue
    prev = vjs = 0
    if top is not None:
        d = top.FindAll(U.TreeScope_Descendants, auto.CreateTrueCondition())
        for k in range(d.Length):
            c = d.GetElement(k).CurrentClassName or ""
            if "prev-i" in c: prev += 1
            if "vjs-tech" in c: vjs += 1
    return prev, vjs


def trigger(auto, root, card, mode="rightmenu"):
    hwnd = card["hwnd"]
    r = card["rect"]
    sx, sy = (r[0] + r[2]) // 2, (r[1] + r[3]) // 2
    cx, cy = to_client(hwnd, sx, sy)

    menu = False
    if mode == "left":
        # 直接左键 MousePress 卡片，绕开右键菜单
        post(hwnd, WM_MOVE, 0, cx, cy); time.sleep(0.05)
        post(hwnd, WM_LDOWN, MK_L, cx, cy); time.sleep(0.08)
        post(hwnd, WM_LUP, 0, cx, cy); time.sleep(1.5)
    else:
        # 先清上一轮残留菜单，避免旧菜单被误读成当前卡片菜单
        dismiss_residual(auto, root, hwnd)
        # 右键 -> 菜单 -> 左键「播放」
        post(hwnd, WM_MOVE, 0, cx, cy); time.sleep(0.05)
        post(hwnd, WM_RDOWN, MK_R, cx, cy); time.sleep(0.08)
        post(hwnd, WM_RUP, 0, cx, cy)
        # 菜单项可能异步补齐，轮询直到出现「播放」或超时
        m, labels = None, []
        for _ in range(6):
            time.sleep(0.2)
            menus = find_menus(auto, root)
            if menus:
                m = menus[-1]
                labels = menu_items(m, auto)
                if "播放" in labels:
                    break
        if m is None:
            return {"ok": False, "reason": "右键未弹出 context-menu", "hwnd": hex(hwnd)}
        play = None
        items = m.FindAll(U.TreeScope_Descendants, auto.CreateTrueCondition())
        for j in range(items.Length):
            if (items.GetElement(j).CurrentName or "").strip() == "播放":
                play = items.GetElement(j); break
        if play is None:
            return {"ok": False, "reason": f"菜单无「播放」，项={labels[:6]}", "hwnd": hex(hwnd)}
        pr = play.CurrentBoundingRectangle
        px, py = (pr.left + pr.right) // 2, (pr.top + pr.bottom) // 2
        pcx, pcy = to_client(hwnd, px, py)
        post(hwnd, WM_MOVE, 0, pcx, pcy); time.sleep(0.05)
        post(hwnd, WM_LDOWN, MK_L, pcx, pcy); time.sleep(0.08)
        post(hwnd, WM_LUP, 0, pcx, pcy); time.sleep(1.5)
        menu = True

    prev, vjs = _probe(auto, root, hwnd)
    played = vjs > 0 or prev == 0
    return {"ok": played, "reason": "抽屉已打开" if played else "点击后未检测到播放器层",
            "hwnd": hex(hwnd), "card_index": card["index"], "rect": r,
            "mode": mode, "menu": menu, "played": played, "prev_i": prev, "vjs": vjs}


def close_play_tab(auto, root):
    """定位 TabStrip 内播放 tab 的关闭钮，PostMessage 左键关掉它，切回网格。"""
    pids = app_pids()
    tops = root.FindAll(U.TreeScope_Children, auto.CreatePropertyCondition(
        U.UIA_ControlTypePropertyId, U.UIA_WindowControlTypeId))
    target = None
    for i in range(tops.Length):
        top = tops.GetElement(i)
        try:
            if int(top.CurrentProcessId) not in pids:
                continue
            hwnd = top.CurrentNativeWindowHandle
            d = top.FindAll(U.TreeScope_Descendants, auto.CreateTrueCondition())
            btns, vjs = [], 0
            for j in range(d.Length):
                e = d.GetElement(j)
                cls = e.CurrentClassName or ""
                n = (e.CurrentName or "").strip()
                r = e.CurrentBoundingRectangle
                if "vjs-tech" in cls or "feed-video" in cls:
                    vjs += 1
                # TabStrip 内的 tab 关闭钮：y≈87、x<1623；排除顶层 caption(1663+) 与后退钮
                if n == "关闭" and r.top < 120 and r.left < 1623:
                    btns.append((e, r))
            # 守卫：纯网格态（无播放器层）不点任何 tab 关闭钮，避免误关网格 tab
            if vjs == 0:
                continue
            if not btns:
                continue
            # 播放 tab 在右，取最右关闭钮
            btns.sort(key=lambda b: b[1].right)
            btn, br = btns[-1]
            sx, sy = (br.left + br.right) // 2, (br.top + br.bottom) // 2
            cx, cy = to_client(hwnd, sx, sy)
            post(hwnd, WM_MOVE, 0, cx, cy); time.sleep(0.05)
            post(hwnd, WM_LDOWN, MK_L, cx, cy); time.sleep(0.08)
            post(hwnd, WM_LUP, 0, cx, cy); time.sleep(1.0)
            # 复核：该窗 vjs-tech 是否清空
            d2 = top.FindAll(U.TreeScope_Descendants, auto.CreateTrueCondition())
            vjs2 = sum(1 for k in range(d2.Length)
                       if "vjs-tech" in (d2.GetElement(k).CurrentClassName or ""))
            return {"ok": vjs2 == 0, "reason": "播放 tab 已关闭" if vjs2 == 0 else "关闭后仍有播放器层",
                    "hwnd": hex(hwnd), "before_vjs": vjs, "after_vjs": vjs2,
                    "close_rect": [br.left, br.top, br.right, br.bottom]}
        except Exception as ex:
            return {"ok": False, "reason": f"异常: {ex}"}
    return {"ok": True, "reason": "已是网格态，无需关闭播放 tab", "before_vjs": 0, "after_vjs": 0}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", type=int, default=None)
    ap.add_argument("--desc", default="")
    ap.add_argument("--seconds", type=int, default=None)
    ap.add_argument("--like", type=int, default=None)
    ap.add_argument("--close-tab", action="store_true", help="关掉播放 tab，回网格")
    ap.add_argument("--mode", choices=["rightmenu", "left"], default="rightmenu",
                    help="rightmenu=右键菜单点播放；left=直接左键点卡片")
    args = ap.parse_args()

    comtypes.client.GetModule("UIAutomationCore.dll")
    auto = comtypes.client.CreateObject(U.CUIAutomation._reg_clsid_, interface=U.IUIAutomation)
    root = auto.GetRootElement()

    if args.close_tab:
        print(json.dumps(close_play_tab(auto, root), ensure_ascii=False))
        return

    cards = find_cards(auto, root)
    if not cards:
        print(json.dumps({"ok": False, "reason": "未找到主页网格卡片（当前可能在播放抽屉态）", "cards": 0},
                         ensure_ascii=False))
        return
    card, how = match(cards, args)
    if card is None:
        print(json.dumps({"ok": False, "reason": how, "cards": len(cards)}, ensure_ascii=False))
        return
    res = trigger(auto, root, card, mode=args.mode)
    res["match"] = how
    res["cards"] = len(cards)
    res["desc"] = card["desc"][:30]
    print(json.dumps(res, ensure_ascii=False))


if __name__ == "__main__":
    main()
