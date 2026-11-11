#!/usr/bin/env bash
# 豆包桌面端(Mac)清理瘦身 / 可选重启
set -euo pipefail

APP_DIR="${HOME}/Library/Application Support/Doubao"
CACHE_DIR="${HOME}/Library/Caches/Doubao"
SESS_DIR="${APP_DIR}/Default/.doubao/agent_mode/workspace/.sessions"
ARCH_DIR="${APP_DIR}/_archive"
LOG_DIR="${HOME}/Library/Logs/doubao-cleaner"
LOG="${LOG_DIR}/clean.log"

DRY_RUN=0
DO_RESTART=0
KEEP_LOG_DAYS=1        # 日志保留天数（1 = 只留今天）
ARCHIVE_SESSION_DAYS=7  # 超过 N 天没动过的本地会话工作区才归档
KEEP_ARCHIVE_DAYS=120   # 归档区保留天数
WITH_GECKO=0
WITH_WEB_ARCHIVE=1     # 是否顺带归档网页版(doubao.com)的历史会话
WEB_ARCHIVE_DAYS=7     # 网页版只归档这么多天之前的会话
WEB_ARCHIVE_PASSES=10  # 网页版每轮能看到的会话有限，多跑几轮把积压往更早处挖

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --restart) DO_RESTART=1; shift ;;
    --keep-log-days) KEEP_LOG_DAYS="$2"; shift 2 ;;
    --archive-session-days) ARCHIVE_SESSION_DAYS="$2"; shift 2 ;;
    --keep-archive-days) KEEP_ARCHIVE_DAYS="$2"; shift 2 ;;
    --gecko-cache) WITH_GECKO=1; shift ;;
    --no-web-archive) WITH_WEB_ARCHIVE=0; shift ;;
    --web-archive-days) WEB_ARCHIVE_DAYS="$2"; shift 2 ;;
    --web-archive-passes) WEB_ARCHIVE_PASSES="$2"; shift 2 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$LOG_DIR"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

# 日志超过 2MB 自动截断，避免自己变成新的垃圾
if [[ -f "$LOG" && $(stat -f%z "$LOG" 2>/dev/null || echo 0) -gt 2097152 ]]; then
  : > "$LOG"
fi

size_mb() { du -sm "$1" 2>/dev/null | awk '{print $1}'; }

# 清空目录内容但保留目录本身；被占用的文件跳过
clean_dir() {
  local dir="$1" label="$2" mb
  [[ -d "$dir" ]] || return 0
  mb=$(size_mb "$dir" || echo 0)
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[预演] ${label}: 可释放 ${mb}MB"
    return 0
  fi
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  log "${label}: 释放 ${mb}MB"
}

# 0) 网页版历史会话归档（依赖 opencli + Chrome；必须在重启豆包之前跑，
#    因为 opencli 装在豆包的 sandbox_runtime 里，重启会带走它）
if [[ "$WITH_WEB_ARCHIVE" == "1" && -f "${SCRIPT_DIR}/doubao_web_archive.py" ]]; then
  py_bin="$(command -v python3 || echo /usr/bin/python3)"
  web_args=(--days "$WEB_ARCHIVE_DAYS" --session doubao-web-archive)
  [[ "$DRY_RUN" == "1" ]] && web_args+=(--dry-run)
  total_ok=0
  for pass in $(seq 1 "$WEB_ARCHIVE_PASSES"); do
    out="$("$py_bin" "${SCRIPT_DIR}/doubao_web_archive.py" "${web_args[@]}" 2>&1)"
    printf '%s\n' "$out" >>"$LOG"
    if printf '%s' "$out" | grep -q "没有满足条件的会话"; then
      log "网页版归档: 第 ${pass} 轮已无可归档会话"
      break
    fi
    ok="$(printf '%s' "$out" | grep -oE "成功 [0-9]+" | grep -oE "[0-9]+" | head -1)"
    if [[ "${ok:-0}" == "0" ]]; then
      log "网页版归档: 第 ${pass} 轮无新增（opencli 可能不可用，详见 ${LOG_DIR}/web_archive.log）"
      break
    fi
    total_ok=$((total_ok + ${ok:-0}))
    log "网页版归档: 第 ${pass} 轮归档 ${ok} 条（只归档 ${WEB_ARCHIVE_DAYS} 天前）"
  done
  log "网页版归档: 本次共归档 ${total_ok} 条"
fi

# 1) Python 沙箱运行时缓存（有进程引用则跳过）
if [[ -d "${APP_DIR}/sandbox_runtime/.cache/python" ]]; then
  if pgrep -f "sandbox_runtime/.cache/python" >/dev/null 2>&1; then
    log "跳过 Python 沙箱缓存：正被进程占用"
  else
    clean_dir "${APP_DIR}/sandbox_runtime/.cache/python" "Python 沙箱缓存"
  fi
fi

# 2) 滚动日志：保留最近 N 天
if [[ -d "${APP_DIR}/sdk_storage/log" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[预演] 历史日志: $(find "${APP_DIR}/sdk_storage/log" -maxdepth 1 -type f \( -name '*.log' -o -name '*.alaudalog' \) -mtime +$((KEEP_LOG_DAYS-1)) -exec du -sk {} + 2>/dev/null | awk '{s+=$1} END{printf "%d", s/1024}')MB"
  else
    find "${APP_DIR}/sdk_storage/log" -maxdepth 1 -type f \( -name '*.log' -o -name '*.alaudalog' \) -mtime +$((KEEP_LOG_DAYS-1)) -delete 2>/dev/null || true
    log "历史日志: 保留最近 ${KEEP_LOG_DAYS} 天"
  fi
fi

# 3) Electron 缓存 / JS 编译缓存
clean_dir "${CACHE_DIR}/Default/Cache" "网络与图片缓存"
clean_dir "${CACHE_DIR}/Default/Code Cache" "JS 编译缓存"
clean_dir "${CACHE_DIR}/Default/GPUCache" "GPU 缓存"

# 4) 网页内核缓存（默认不动，--gecko-cache 才清）
if [[ "$WITH_GECKO" == "1" ]]; then
  clean_dir "${APP_DIR}/gecko_cache" "网页内核缓存"
fi

# 5) 历史会话工作区归档（保留最近修改过的，含当前会话）
if [[ -d "$SESS_DIR" ]]; then
  stamp=$(date +%F)
  target="${ARCH_DIR}/sessions-${stamp}"
  count=0
  mkdir -p "$target"
  # 按修改时间挑老的；当前会话一定在最近修改里，天然被排除
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    if [[ "$DRY_RUN" == "1" ]]; then
      count=$((count+1)); continue
    fi
    mv "$d" "$target/" 2>/dev/null && count=$((count+1)) || true
  done < <(find "$SESS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"${ARCHIVE_SESSION_DAYS}" 2>/dev/null)
  if [[ "$count" -gt 0 ]]; then
    log "会话归档: ${count} 个超过 ${ARCHIVE_SESSION_DAYS} 天未活动的会话 -> ${target}"
  fi
fi

# 6) 归档区按保留期清理（目录名形如 sessions-YYYY-MM-DD）
if [[ -d "$ARCH_DIR" ]]; then
  cutoff=$(date -v "-${KEEP_ARCHIVE_DAYS}d" +%Y-%m-%d 2>/dev/null || date -d "-${KEEP_ARCHIVE_DAYS} days" +%Y-%m-%d)
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    name=$(basename "$d")
    day=${name#sessions-}
    # 只处理严格符合 YYYY-MM-DD 的目录，且严格早于截止日（不删边界当天）
    if [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$day" < "$cutoff" ]]; then
      if [[ "$DRY_RUN" == "1" ]]; then
        log "[预演] 过期归档: ${name}"
      else
        rm -rf "$d" && log "过期归档已删除: ${name}"
      fi
    fi
  done < <(find "$ARCH_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

# 结果汇总
if [[ "$DRY_RUN" != "1" ]]; then
  log "清理后占用: 数据目录 $(size_mb "$APP_DIR")MB / 缓存目录 $(size_mb "$CACHE_DIR")MB"
fi

# 7) 重启豆包
if [[ "$DO_RESTART" == "1" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[预演] 将重启豆包"
  else
    # 从豆包会话内触发时，自身会被一起杀掉，必须委托给 launchd 独立进程
    case "${XPC_SERVICE_NAME:-}" in
      com.hust.doubao-cleaner*) : ;;
      *)
        helper_plist="${HOME}/Library/LaunchAgents/com.hust.doubao-restart.plist"
        if [[ -f "$helper_plist" ]]; then
          log "委托 launchd 执行重启（避免被自身进程终止）"
          launchctl kickstart -k "gui/$(id -u)/com.hust.doubao-restart" >/dev/null 2>&1 || log "委托重启失败，请手动重启豆包"
          exit 0
        fi
        ;;
    esac
    if pgrep -x Doubao >/dev/null 2>&1; then
      log "重启豆包：退出中"
      osascript -e 'quit app "Doubao"' >/dev/null 2>&1 || true
      for _ in $(seq 1 15); do pgrep -x Doubao >/dev/null 2>&1 || break; sleep 1; done
      if pgrep -x Doubao >/dev/null 2>&1; then
        log "优雅退出超时，强制结束"
        pkill -x Doubao 2>/dev/null || true
        sleep 2
      fi
    fi
    open -a "Doubao" >/dev/null 2>&1 && log "豆包已重新启动" || log "豆包启动失败，请手动打开"
  fi
fi

log "完成"
