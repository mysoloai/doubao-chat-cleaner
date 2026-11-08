#!/usr/bin/env python3
"""网页版豆包(doubao.com)历史会话归档 —— 默认只归档「N 天前」的会话。

年龄判定顺序（越靠前越可信）：
  1) 本地工作区 `.../agent_mode/workspace/.sessions/<会话id>` 的目录修改时间
  2) 归档区 `_archive/sessions-*/manifest.tsv` 里的 `last_modified`
  3) 两者都没有 → 视为「未知年龄」，**默认一并归档**（网页端新建的会话本来就没本地痕迹），--keep-unknown 才保留

依赖 opencli 2.x + 已登录 doubao.com 的 Chrome/Browser Bridge。

用法：
  python3 scripts/doubao_web_archive.py --dry-run          # 只统计，不动手
  python3 scripts/doubao_web_archive.py                    # 归档 30 天前的会话
  python3 scripts/doubao_web_archive.py --days 90
  python3 scripts/doubao_web_archive.py --keep-unknown     # 保留年龄未知的
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path

APP_DIR = Path(os.environ.get("DOUBAO_APP_DIR") or (Path.home() / "Library/Application Support/Doubao"))
SESS_DIR = APP_DIR / "Default/.doubao/agent_mode/workspace/.sessions"
ARCH_DIR = APP_DIR / "_archive"
LOG_DIR = Path.home() / "Library/Logs/doubao-chat-cleaner"
LOG = LOG_DIR / "web_archive.log"
STATE_FILE = Path.home() / ".local/share/doubao-chat-cleaner/web_archived.json"
KEEP_FILE = Path.home() / ".local/share/doubao-chat-cleaner/web_keep.json"

BATCH_SIZE = 25
MAX_EXPAND_ROUNDS = 3

OPERATE_TYPE_ARCHIVE = 8
API_BASE = "https://www.doubao.com/im/conversation/batch_operate"
API_QS = ("version_code=20800&language=zh&device_platform=web&doubao_device_platform=web"
          "&aid=497858&real_aid=497858&pkg_type=release_version&region=CN&sys_region=CN"
          "&samantha_web=1&web_platform=browser&use-olympus-account=1")


def log(msg: str) -> None:
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    print(line, flush=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def find_opencli() -> str | None:
    env = os.environ.get("DOUBAO_OPENCLI")
    if env and Path(env).exists():
        return env
    hits = sorted(glob.glob(str(APP_DIR / "sandbox_runtime/bases/*/bin/opencli")))
    if hits:
        return hits[-1]
    from shutil import which
    return which("opencli")


class Browser:
    def __init__(self, opencli: str, session: str):
        self.bin = opencli
        self.session = session

    def _run(self, args: list[str], timeout: int = 45) -> str:
        p = subprocess.run([self.bin, "browser", *args, "--session", self.session],
                           capture_output=True, text=True, timeout=timeout)
        return p.stdout.strip()

    def eval(self, js: str):
        out = self._run(["eval", js])
        if not out:
            return None
        try:
            envelope = json.loads(out[out.index("{"):out.rindex("}") + 1])
        except Exception:
            return None
        data = envelope.get("data")
        if isinstance(data, str) and data.strip()[:1] in "{[":
            try:
                return json.loads(data)
            except Exception:
                return data
        return data

    def open(self, url: str) -> None:
        self._run(["open", url], timeout=60)

    def click(self, *args: str) -> str:
        return self._run(["click", *args], timeout=45)


EXPAND_JS = """(()=>{const bs=[...document.querySelectorAll('button')]
 .filter(b=>/展开更多对话|展开更多项目/.test(b.innerText));bs.forEach(b=>b.click());return bs.length})()"""

COLLECT_JS = """(()=>{const pinned=document.querySelector('[data-testid=pinned-section]');
const arr=[...document.querySelectorAll('a[id^=conversation_]')]
 .filter(a=>!(pinned&&pinned.contains(a)))
 .map(a=>({id:a.id.replace('conversation_',''),title:(a.innerText||'').trim()}));
return JSON.stringify(arr)})()"""


def ui_archive(bw: Browser, cid: str) -> bool:
    """接口报成功但侧栏没消失时，走界面菜单归档（实测对系统会话/部分老会话有效）。"""
    bw.open(f"https://www.doubao.com/chat/{cid}")
    time.sleep(5)
    r = bw.click("--testid", "conversation_header_more_button")
    if '"clicked":true' not in r:
        return False
    time.sleep(0.6)
    bw.click("--role", "menuitem", "--name", "归档")
    time.sleep(2)
    left = bw.eval(f"!!document.getElementById('conversation_{cid}')")
    return left is False


def local_activity_time(cid: str, manifest_index: dict[str, datetime]) -> datetime | None:
    d = SESS_DIR / cid
    if d.is_dir():
        try:
            return datetime.fromtimestamp(d.stat().st_mtime)
        except OSError:
            pass
    return manifest_index.get(cid)


def load_keep_file() -> set[str]:
    """白名单：撤销归档/手动保留的会话 id，定时任务不再归档它们。"""
    try:
        data = json.loads(KEEP_FILE.read_text(encoding="utf-8"))
    except Exception:
        return set()
    if isinstance(data, dict):
        data = data.get("ids") or []
    if not isinstance(data, list):
        return set()
    return {str(x).strip() for x in data if str(x).strip()}


def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")


def build_manifest_index() -> dict[str, datetime]:
    idx: dict[str, datetime] = {}
    for path in sorted(glob.glob(str(ARCH_DIR / "sessions-*" / "manifest.tsv")))[-5:]:
        try:
            with open(path, encoding="utf-8") as fh:
                for row in csv.DictReader(fh, delimiter="\t"):
                    cid = (row.get("session_id") or "").strip()
                    ts = (row.get("last_modified") or "").strip()
                    if not cid or not ts:
                        continue
                    try:
                        idx[cid] = datetime.strptime(ts, "%Y-%m-%d %H:%M")
                    except ValueError:
                        continue
        except OSError:
            continue
    return idx


def api_archive(bw: Browser, ids: list[str]) -> set[str]:
    body = {"cmd": 1125,
            "uplink_body": {"batch_operate_conv_uplink_body": {
                "operate_type": OPERATE_TYPE_ARCHIVE,
                "conversation_id_list": ids}},
            "sequence_id": str(uuid.uuid4()), "channel": 2, "version": "1"}
    js = ("(()=>{window.__arch={};fetch(%s,{method:'POST',credentials:'include',"
          "headers:{'Content-Type':'application/json; encoding=utf-8'},body:%s})"
          ".then(r=>r.json()).then(j=>{window.__arch.res=j})"
          ".catch(e=>{window.__arch.res={err:String(e)}});return 'fired'})()"
          % (json.dumps(API_BASE + "?" + API_QS), json.dumps(json.dumps(body)))
          )
    bw.eval(js)
    for _ in range(25):
        time.sleep(0.8)
        res = bw.eval("window.__arch&&window.__arch.res?window.__arch.res:null")
        if isinstance(res, dict) and ("downlink_body" in res or "err" in res):
            break
    else:
        return set()
    if "err" in res:
        log(f"  接口调用失败: {res['err']}")
        return set()
    try:
        body_out = res["downlink_body"]["batch_operate_conv_downlink_body"]
    except (KeyError, TypeError):
        log(f"  接口返回异常: {str(res)[:160]}")
        return set()
    return {it["conversation_id"] for it in body_out.get("conversation_list", [])
            if it.get("success")}


def main() -> int:
    ap = argparse.ArgumentParser(description="归档网页版豆包 N 天前的历史会话（年龄未知的一并归档）")
    ap.add_argument("--days", type=int, default=30, help="只归档这个天数之前活跃的会话（默认 30）")
    ap.add_argument("--dry-run", action="store_true", help="只统计不归档")
    ap.add_argument("--no-ui-fallback", action="store_true",
                    help="不改用界面菜单兜底归档（默认会兜底接口假成功的会话）")
    ap.add_argument("--ui-limit", type=int, default=6, help="每轮界面兜底最多处理几条")
    ap.add_argument("--keep-unknown", action="store_true",
                    help="保留年龄未知的会话（默认是一并归档）")
    ap.add_argument("--include-unknown", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--session", default="doubao-web-archive", help="opencli 会话名")
    ap.add_argument("--keep", action="append", default=[], help="始终保留的会话 id，可重复")
    ap.add_argument("--limit", type=int, default=0, help="本次最多归档多少条（0 = 不限）")
    args = ap.parse_args()

    opencli = find_opencli()
    if not opencli:
        log("未找到 opencli，跳过网页版归档")
        return 2

    bw = Browser(opencli, args.session)
    # 加时间戳强制重新加载，否则复用的旧标签页会一直显示上一次的（残缺）侧栏
    bw.open(f"https://www.doubao.com/chat?t={int(time.time())}")
    time.sleep(4)

    for _ in range(MAX_EXPAND_ROUNDS):
        n = bw.eval(EXPAND_JS)
        time.sleep(1.2)
        if not n:
            break

    def collect():
        raw = bw.eval(COLLECT_JS) or []
        if isinstance(raw, str):
            try:
                raw = json.loads(raw)
            except Exception:
                raw = []
        return raw

    items = collect()
    # 页面可能还没渲染完（刚打开不久），少于 2 条时再等一轮复查，避免把"没加载"当成"已清空"
    for _ in range(2):
        if len(items) >= 2:
            break
        time.sleep(4)
        items = collect()
    if not items:
        log("侧栏没有可见会话，无需归档")
        return 0

    manifest = build_manifest_index()
    cutoff = datetime.now() - timedelta(days=args.days)
    keep = set(args.keep) | load_keep_file()
    state = load_state()

    targets, fresh, unknown, stuck = [], [], [], []
    for it in items:
        cid = it["id"]
        if cid in keep:
            continue
        if cid in state:
            # 之前接口返回 success 但会话仍在侧栏 —— 不再重复提交，避免空转
            stuck.append(it)
            continue
        ts = local_activity_time(cid, manifest)
        if ts is None:
            unknown.append(it)
        elif ts >= cutoff:
            fresh.append((it, ts))
        else:
            targets.append((it, ts))

    log(f"可见 {len(items)} 条：待归档 {len(targets)}、"
        f"最近 {args.days} 天内 {len(fresh)}、年龄未知 {len(unknown)}、"
        f"已归档过仍显示 {len(stuck)}")
    if not args.keep_unknown:
        targets.extend((it, None) for it in unknown)
        log(f"含未知年龄后待归档 {len(targets)} 条")

    if args.dry_run:
        for it, ts in targets[:15]:
            when = ts.strftime("%Y-%m-%d %H:%M") if ts else "未知"
            log(f"  [预演] 归档 {it['id']} {when} {(it['title'] or '')[:28]}")
        log(f"[预演] 将归档 {len(targets)} 条")
        return 0

    if args.limit:
        targets = targets[:args.limit]
    # 台账里已有、却仍出现在侧栏的会话：接口是"假成功"，改用界面菜单兜底
    if stuck and not args.dry_run and not args.no_ui_fallback:
        for it in stuck[:args.ui_limit]:
            entry = state.get(it["id"], {})
            if entry.get("ui_tries", 0) >= 3:
                continue
            entry["ui_tries"] = entry.get("ui_tries", 0) + 1
            state[it["id"]] = entry
            if ui_archive(bw, it["id"]):
                log(f"  界面兜底归档(顽固) {it['id']}")
                state[it["id"]] = {"at": datetime.now().strftime("%Y-%m-%d %H:%M"), "ui": True}
        save_state(state)

    if not targets:
        log("没有满足条件的会话")
        return 0

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    report = LOG_DIR / f"web_archive_{datetime.now():%Y%m%d_%H%M}.csv"
    ok = fail = 0
    with report.open("w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["conversation_id", "last_active", "title", "result"])
        for i in range(0, len(targets), BATCH_SIZE):
            chunk = targets[i:i + BATCH_SIZE]
            got = api_archive(bw, [c[0]["id"] for c in chunk])
            for it, ts in chunk:
                res = "ok" if it["id"] in got else "failed"
                ok += res == "ok"
                fail += res != "ok"
                w.writerow([it["id"], ts.strftime("%Y-%m-%d %H:%M") if ts else "",
                            it["title"][:60], res])
                if res == "ok":
                    state[it["id"]] = {"at": datetime.now().strftime("%Y-%m-%d %H:%M")}
            fh.flush()
            save_state(state)
            log(f"  批次 {i // BATCH_SIZE + 1}: 成功 {ok} / 失败 {fail}")
    ui_ok = 0
    if not args.dry_run and not args.no_ui_fallback and ok:
        # 回读 DOM：接口返回 success 的会话里，仍在侧栏的就是"假成功"，改走界面菜单
        bw.open(f"https://www.doubao.com/chat?t={int(time.time())}")
        time.sleep(4)
        still = collect() or []
        visible = {i["id"] for i in still}
        done = [c[0]["id"] for c in targets]
        stuck = [cid for cid in done if cid in visible][:args.ui_limit]
        for cid in stuck:
            if ui_archive(bw, cid):
                ui_ok += 1
                state[cid] = {"at": datetime.now().strftime("%Y-%m-%d %H:%M"), "ui": True}
                log(f"  界面兜底归档 {cid}")
            else:
                state.setdefault(cid, {})["ui_fail"] = True
        save_state(state)

    log(f"完成：成功 {ok}，失败 {fail}，界面兜底 {ui_ok}，清单 {report}")
    return 0 if (fail == 0 or ui_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
