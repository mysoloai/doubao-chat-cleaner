#!/usr/bin/env bash
# 仅供 launchd 调用：退出并重新启动豆包（在豆包进程树之外执行，不会被自身退出杀掉）
set -uo pipefail
LOG_DIR="${HOME}/Library/Logs/doubao-cleaner"
LOG="${LOG_DIR}/restart.log"
mkdir -p "$LOG_DIR"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

if [[ $(stat -f%z "$LOG" 2>/dev/null || echo 0) -gt 1048576 ]]; then : > "$LOG"; fi

log "--- 开始重启豆包 ---"
if pgrep -x Doubao >/dev/null 2>&1; then
  osascript -e 'quit app "Doubao"' >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do pgrep -x Doubao >/dev/null 2>&1 || break; sleep 1; done
  if pgrep -x Doubao >/dev/null 2>&1; then
    log "优雅退出超时，强制结束"
    pkill -x Doubao 2>/dev/null || true
    sleep 2
  fi
  log "已退出"
else
  log "豆包未在运行"
fi
open -a "Doubao" >/dev/null 2>&1 && log "已重新启动" || log "启动失败，需要手动打开"
log "--- 完成 ---"
