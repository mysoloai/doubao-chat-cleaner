#!/usr/bin/env bash
# 豆包 macOS 桌面端本地瘦身：清缓存/日志、归档旧会话工作区
# 用法:
#   bash scripts/clean_local.sh --dry-run
#   bash scripts/clean_local.sh
#   bash scripts/clean_local.sh --gecko-cache --archive-session-days 30
set -euo pipefail

APP_DIR="${DOUBAO_APP_DIR:-$HOME/Library/Application Support/Doubao}"
CACHE_DIR="$HOME/Library/Caches/Doubao"
SESS_DIR="$APP_DIR/Default/.doubao/agent_mode/workspace/.sessions"
ARCH_DIR="$APP_DIR/_archive"
LOG_DIR="$HOME/Library/Logs/doubao-chat-cleaner"
LOG="$LOG_DIR/clean.log"

DRY_RUN=0
WITH_GECKO=0
KEEP_LOG_DAYS=1
ARCHIVE_SESSION_DAYS=7
KEEP_ARCHIVE_DAYS=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --gecko-cache) WITH_GECKO=1; shift ;;
    --keep-log-days) KEEP_LOG_DAYS="$2"; shift 2 ;;
    --archive-session-days) ARCHIVE_SESSION_DAYS="$2"; shift 2 ;;
    --keep-archive-days) KEEP_ARCHIVE_DAYS="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
size_mb() { du -sm "$1" 2>/dev/null | awk '{print $1}'; }

[[ -d "$APP_DIR" ]] || { echo "没找到豆包数据目录: $APP_DIR" >&2; exit 1; }

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

log "===== 开始（dry-run=${DRY_RUN}） ====="

# 1) Python 沙箱运行时缓存（有进程引用则跳过）
if [[ -d "$APP_DIR/sandbox_runtime/.cache/python" ]]; then
  if pgrep -f "sandbox_runtime/.cache/python" >/dev/null 2>&1; then
    log "跳过 Python 沙箱缓存：正被进程占用"
  else
    clean_dir "$APP_DIR/sandbox_runtime/.cache/python" "Python 沙箱缓存"
  fi
fi

# 2) 滚动日志（保留今天）
if [[ -d "$APP_DIR/sdk_storage/log" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    mb=$(find "$APP_DIR/sdk_storage/log" -maxdepth 1 -type f \( -name '*.log' -o -name '*.alaudalog' \) -mtime +$((KEEP_LOG_DAYS-1)) -exec du -sk {} + 2>/dev/null | awk '{s+=$1} END{printf "%d", s/1024}')
    log "[预演] 历史日志: 可释放 ${mb:-0}MB"
  else
    find "$APP_DIR/sdk_storage/log" -maxdepth 1 -type f \( -name '*.log' -o -name '*.alaudalog' \) -mtime +$((KEEP_LOG_DAYS-1)) -delete 2>/dev/null || true
    log "历史日志: 保留最近 ${KEEP_LOG_DAYS} 天"
  fi
fi

# 3) Electron / JS 缓存
for d in "$CACHE_DIR/Default/Cache" "$CACHE_DIR/Default/Code Cache" "$CACHE_DIR/Default/GPUCache"; do
  clean_dir "$d" "缓存 $(basename "$d")"
done

# 4) 网页内核缓存（默认不动）
if [[ "$WITH_GECKO" == "1" ]]; then
  clean_dir "$APP_DIR/gecko_cache" "网页内核缓存(gecko)"
else
  log "网页内核缓存: 跳过（加 --gecko-cache 才清）"
fi

# 5) 旧会话工作区 → 归档区（保留最近修改过的）
if [[ -d "$SESS_DIR" ]]; then
  target="$ARCH_DIR/sessions-$(date +%Y-%m-%d)"
  count=0
  while IFS= read -r -d '' d; do
    count=$((count+1))
    if [[ "$DRY_RUN" == "1" ]]; then
      log "[预演] 归档会话 $(basename "$d")"
      continue
    fi
    mkdir -p "$target"
    mv "$d" "$target/" 2>/dev/null || true
    printf '%s\t%s\n' "$(basename "$d")" "$(date -r "$d" '+%F %T' 2>/dev/null || echo '')" >> "$target/manifest.tsv"
  done < <(find "$SESS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$ARCHIVE_SESSION_DAYS" -print0 2>/dev/null)
  log "会话归档: ${count} 个超过 ${ARCHIVE_SESSION_DAYS} 天未活动的会话 -> ${target}"
fi

# 6) 归档区按保留期清理
if [[ -d "$ARCH_DIR" ]]; then
  for d in "$ARCH_DIR"/sessions-*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"; day="${name#sessions-}"
    cutoff=$(date -v-"${KEEP_ARCHIVE_DAYS}"d +%Y-%m-%d 2>/dev/null || echo "")
    [[ -n "$cutoff" && "$day" < "$cutoff" ]] || continue
    if [[ "$DRY_RUN" == "1" ]]; then log "[预演] 过期归档: $name"; else rm -rf "$d" && log "过期归档已删除: $name"; fi
  done
fi

log "清理后占用: 数据目录 $(size_mb "$APP_DIR")MB / 缓存目录 $(size_mb "$CACHE_DIR")MB"
log "完成"
