#!/usr/bin/env python3
"""撤销归档：把豆包网页版已归档的会话恢复回来（按项目整体 / 按单条会话）。

依赖 opencli 2.x + 已登录 doubao.com 的 Chrome/Browser Bridge，与 doubao_web_archive.py 相同。

用法：
  python3 scripts/doubao_web_restore.py --list                       # 列项目 + 各项目已归档条数
  python3 scripts/doubao_web_restore.py --project newwork --dry-run  # 看将恢复哪些
  python3 scripts/doubao_web_restore.py --project newwork            # 整项目恢复
  python3 scripts/doubao_web_restore.py --conversation-id 123 --conversation-id 456
  python3 scripts/doubao_web_restore.py --project newwork --no-keep  # 不写白名单

关键事实（实测 2026-11-08）：
  - batch_operate（cmd 1125）：operate_type 8 = 归档，9 = 取消归档
  - 项目会话清单 GET 不到：POST /im/project/list，uplink {limit:20}（空对象会报 712010202 参数错误），
    返回的 projects[].conversations 含该项目全部会话（**已归档的也在里面**），带 name/create_time/update_time
  - 归档状态：POST /im/conversation/batch_get（cmd 1111）→ conversation_info_list[].status
    1 = AVAILABLE（正常），8 = ARCHIVE（已归档）。这是恢复前后最可靠的核验口径
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HOME = Path.home()
APP_DIR = HOME / "Library/Application Support/Doubao"
LOG_DIR = HOME / "Library/Logs/doubao-cleaner"
LOG = LOG_DIR / "web_restore.log"
KEEP_FILE = HOME / ".local/share/doubao-cleaner/web_keep.json"
STATE_FILE = HOME / ".local/share/doubao-cleaner/web_archived.json"

API_QS = ("version_code=20800&language=zh&device_platform=web&doubao_device_platform=web"
          "&aid=497858&real_aid=497858&pkg_type=release_version&region=CN&sys_region=CN"
          "&samantha_web=1&web_platform=browser&use-olympus-account=1")

CMD_LIST_PROJECTS = 4605
CMD_BATCH_GET = 1111
CMD_BATCH_OPERATE = 1125
OPERATE_TYPE_CANCEL_ARCHIVE = 9

STATUS_AVAILABLE = 1
STATUS_ARCHIVE = 8


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


def js_post(path: str, payload: dict) -> str:
    return (
        "(async()=>{const qs=" + json.dumps(API_QS) + ";"
        "const body=" + json.dumps(payload) + ";"
        "const r=await fetch(" + json.dumps("https://www.doubao.com" + path) + "+'?'+qs,"
        "{method:'POST',credentials:'include',headers:{'Content-Type':'application/json; encoding=utf-8',"
        "'Agw-Js-Conv':'str'},body:JSON.stringify(body)});"
        "return JSON.stringify(await r.json());})()"
    )


class Browser:
    def __init__(self, opencli: str, session: str):
        self.bin = opencli
        self.session = session

    def _run(self, args: list[str], timeout: int = 60) -> str:
        p = subprocess.run([self.bin, "browser", *args, "--session", self.session],
                           capture_output=True, text=True, timeout=timeout)
        if p.returncode != 0 and not p.stdout.strip():
            raise RuntimeError(f"opencli 调用失败: {(p.stderr or '').strip()[:200]}")
        return p.stdout.strip()

    def open(self, url: str) -> None:
        self._run(["open", url])

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

    def call(self, path: str, cmd: int, uplink_key: str, body: dict) -> dict:
        payload = {"cmd": cmd, "uplink_body": {uplink_key: body},
                   "sequence_id": f"{int(time.time())}-{os.getpid()}", "channel": 2, "version": "1"}
        res = self.eval(js_post(path, payload))
        return res if isinstance(res, dict) else {}


def list_projects(bw: Browser) -> list[dict]:
    res = bw.call("/im/project/list", CMD_LIST_PROJECTS, "list_projects_uplink_body", {"limit": 50})
    code = res.get("status_code")
    if code != 0:
        raise RuntimeError(f"项目列表接口失败: {code} {res.get('status_desc')}")
    return ((res.get("downlink_body") or {}).get("list_projects_downlink_body") or {}).get("projects") or []


def conv_status(bw: Browser, ids: list[str]) -> dict[str, dict]:
    """批量查会话状态：1 = 正常，8 = 已归档。"""
    out: dict[str, dict] = {}
    for i in range(0, len(ids), 25):
        chunk = ids[i:i + 25]
        res = bw.call("/im/conversation/batch_get", CMD_BATCH_GET, "batch_get_conv_info_uplink_body",
                      {"conversation_id": chunk, "option": {"recent_message_count_per_conv": 0}, "ext": {}})
        items = ((res.get("downlink_body") or {}).get("batch_get_conv_info_downlink_body") or {}).get("conversation_info_list") or []
        for c in items:
            out[str(c.get("conversation_id"))] = {"name": c.get("name") or "", "status": c.get("status")}
    return out


def cancel_archive(bw: Browser, ids: list[str], project_id: str) -> dict:
    body = {"operate_type": OPERATE_TYPE_CANCEL_ARCHIVE,
            "conversation_id_list": ids,
            "project_id": project_id or ""}
    res = bw.call("/im/conversation/batch_operate", CMD_BATCH_OPERATE, "batch_operate_conv_uplink_body", body)
    return ((res.get("downlink_body") or {}).get("batch_operate_conv_downlink_body") or {})


def write_keep(ids: list[str]) -> None:
    try:
        data = json.loads(KEEP_FILE.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            data = {"ids": []}
    except Exception:
        data = {"note": "撤销归档/手动保留的会话，定时任务跳过", "ids": []}
    cur = [str(x) for x in (data.get("ids") or [])]
    for cid in ids:
        if cid not in cur:
            cur.append(cid)
    data["ids"] = cur
    KEEP_FILE.parent.mkdir(parents=True, exist_ok=True)
    KEEP_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def drop_state(ids: list[str]) -> None:
    """已恢复的会话从归档台账里移除（白名单兜底，台账只做去重）。"""
    try:
        state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return
    changed = [cid for cid in ids if state.pop(cid, None) is not None]
    if changed:
        STATE_FILE.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")


def resolve_project(projects: list[dict], key: str) -> dict:
    key = str(key).strip()
    for p in projects:
        if str(p.get("project_id")) == key or str(p.get("name") or "") == key:
            return p
    names = "、".join(f"{p.get('name')}({p.get('project_id')})" for p in projects)
    raise SystemExit(f"没找到项目「{key}」。现有：{names}")


def main() -> int:
    ap = argparse.ArgumentParser(description="撤销归档：恢复豆包网页版已归档的会话")
    ap.add_argument("--project", action="append", default=[], help="项目名或 project_id，可重复")
    ap.add_argument("--conversation-id", action="append", default=[], help="单个会话 id，可重复")
    ap.add_argument("--list", action="store_true", help="只列出项目与各项目已归档条数")
    ap.add_argument("--dry-run", action="store_true", help="只显示将恢复哪些，不提交")
    ap.add_argument("--no-keep", action="store_true", help="不写入 web_keep.json 白名单")
    ap.add_argument("--session", default="doubao-web-restore", help="opencli 会话名")
    args = ap.parse_args()

    if not (args.list or args.project or args.conversation_id):
        ap.print_help()
        return 2

    opencli = find_opencli()
    if not opencli:
        raise SystemExit("未找到 opencli（豆包 sandbox_runtime 里没有，PATH 里也没有）")
    bw = Browser(opencli, args.session)
    bw.open(f"https://www.doubao.com/chat?t={int(time.time())}")
    time.sleep(6)

    projects = list_projects(bw)

    if args.list or not (args.project or args.conversation_id):
        for p in projects:
            convs = [c.get("conversation_id") for c in (p.get("conversations") or [])]
            st = conv_status(bw, [str(c) for c in convs]) if convs else {}
            archived = sum(1 for v in st.values() if v.get("status") == STATUS_ARCHIVE)
            log(f"{p.get('name')}\t项目id={p.get('project_id')}\t会话 {len(convs)} 条，其中已归档 {archived} 条")
        return 0

    targets: list[tuple[str, list[str], dict]] = []   # (label, conv_ids, project)
    for key in args.project:
        proj = resolve_project(projects, key)
        convs = [str(c.get("conversation_id")) for c in (proj.get("conversations") or [])]
        st = conv_status(bw, convs) if convs else {}
        archived = [cid for cid in convs if st.get(cid, {}).get("status") == STATUS_ARCHIVE]
        if not archived:
            log(f"项目 {proj.get('name')}：没有已归档的会话，跳过")
            continue
        for cid in archived:
            log(f"  待恢复 {cid} {(st.get(cid,{}).get('name') or '')[:30]}")
        targets.append((f"项目 {proj.get('name')}", archived, proj))

    for cid in args.conversation_id:
        cid = str(cid).strip()
        st = conv_status(bw, [cid]).get(cid)
        if not st:
            log(f"会话 {cid}：查不到详情，跳过")
            continue
        if st.get("status") != STATUS_ARCHIVE:
            log(f"会话 {cid}（{st.get('name','')[:30]}）当前未归档（status={st.get('status')}），跳过")
            continue
        targets.append((f"会话 {cid}", [cid], {}))

    if not targets:
        log("没有需要恢复的会话")
        return 0

    if args.dry_run:
        total = sum(len(ids) for _, ids, _ in targets)
        log(f"[预演] 将恢复 {total} 条（{', '.join(l for l, _, _ in targets)}）")
        return 0

    restored: list[str] = []
    for label, ids, proj in targets:
        res = cancel_archive(bw, ids if proj else ids, str(proj.get("project_id") or ""))
        ok_items = [c for c in (res.get("conversation_list") or []) if c.get("success")]
        log(f"{label}：提交 {len(ids)} 条，接口返回成功 {len(ok_items)} 条，has_failure={res.get('has_failure')}")
        restored.extend(str(c.get("conversation_id")) for c in ok_items)
        time.sleep(1)

    # 回读核验：status 必须从 8 变成 1
    st = conv_status(bw, restored) if restored else {}
    still = [cid for cid in restored if st.get(cid, {}).get("status") != STATUS_AVAILABLE]
    log(f"核验：恢复 {len(restored) - len(still)} 条为正常状态(status=1)，仍归档 {len(still)} 条"
        + (f"：{still}" if still else ""))

    if restored and not args.no_keep:
        write_keep([cid for cid in restored if cid not in still])
        drop_state([cid for cid in restored if cid not in still])
        log(f"已写入白名单 {KEEP_FILE}（定时任务不会再归档这些会话）")

    log("恢复完成后刷新网页侧栏即可看到对应项目重新挂出会话")
    return 0 if not still else 1


if __name__ == "__main__":
    sys.exit(main())
