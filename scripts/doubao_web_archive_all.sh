#!/usr/bin/env bash
# 反复调用 doubao_web_archive.py，直到网页版侧栏只剩「最近 N 天内 + 当前会话」为止。
# 每轮能看到的会话有限（通常 10 条左右，其中可归档 6 条），单次脚本跑不到底，需靠本驱动多轮下探。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAYS="${1:-7}"
MAX_PASSES="${2:-800}"
LOG_DIR="$HOME/Library/Logs/doubao-cleaner"
mkdir -p "$LOG_DIR"
PROGRESS="$LOG_DIR/web_archive_progress.log"
py="$(command -v python3 || echo /usr/bin/python3)"
total=0
for i in $(seq 1 "$MAX_PASSES"); do
  out="$("$py" "$SCRIPT_DIR/doubao_web_archive.py" --days "$DAYS" 2>&1)"
  ok=$(printf '%s' "$out" | grep -oE "成功 [0-9]+" | grep -oE "[0-9]+" | head -1)
  ui=$(printf '%s' "$out" | grep -oE "界面兜底 [0-9]+" | grep -oE "[0-9]+" | head -1)
  n=$(printf '%s' "$out" | grep -oE "可见 [0-9]+" | grep -oE "[0-9]+" | head -1)
  ok=${ok:-0}; ui=${ui:-0}; n=${n:-0}
  total=$((total + ok + ui))
  echo "pass=$i visible=$n api_ok=$ok ui_ok=$ui total=$total $(date +%H:%M:%S)" >>"$PROGRESS"
  if [[ "$ok" == "0" && "$ui" == "0" ]]; then
    [[ "$n" -le 3 ]] && { echo "DONE 收敛，剩余 $n 条" >>"$PROGRESS"; break; }
    sleep 20
    out2="$("$py" "$SCRIPT_DIR/doubao_web_archive.py" --days "$DAYS" 2>&1)"
    ok2=$(printf '%s' "$out2" | grep -oE "成功 [0-9]+" | grep -oE "[0-9]+" | head -1)
    [[ "${ok2:-0}" == "0" ]] && { echo "STALL 复测仍为 0，停机（剩余 $n 条可能是本周内会话或系统通知）" >>"$PROGRESS"; break; }
  fi
  sleep 1
done
echo "结束 total=$total" >>"$PROGRESS"
