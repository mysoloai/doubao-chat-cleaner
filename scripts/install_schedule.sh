#!/usr/bin/env bash
# 安装每日定时清理（macOS launchd）
# 用法:
#   bash scripts/install_schedule.sh --hour 4 --minute 10
#   bash scripts/install_schedule.sh --status
#   bash scripts/install_schedule.sh --run-now
#   bash scripts/install_schedule.sh --uninstall
set -euo pipefail

LABEL="com.doubao-chat-cleaner"
LA_DIR="$HOME/Library/LaunchAgents"
PLIST="$LA_DIR/$LABEL.plist"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$HOME/Library/Logs/doubao-chat-cleaner"
HOUR=4
MINUTE=10

run_once() {
  mkdir -p "$LOG_DIR"
  bash "$HERE/scripts/clean_local.sh" >>"$LOG_DIR/clean.log" 2>&1 || true
  if command -v python3 >/dev/null 2>&1; then
    python3 "$HERE/scripts/doubao_web_archive.py" --days 30 >>"$LOG_DIR/web_archive.log" 2>&1 || true
  fi
}

case "${1:-}" in
  --status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | head -6 || echo "未安装定时任务"
    [[ -f "$PLIST" ]] && echo "plist: $PLIST"
    exit 0 ;;
  --uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "已卸载定时任务"; exit 0 ;;
  --run-now)
    run_once; echo "已立即执行一次，日志见 $LOG_DIR"; exit 0 ;;
  --hour) HOUR="${2:?}" ;;
  --minute) MINUTE="${2:?}" ;;
esac

mkdir -p "$LA_DIR" "$LOG_DIR"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>bash "${HERE}/scripts/clean_local.sh" >>"${LOG_DIR}/clean.log" 2>&1; /usr/bin/python3 "${HERE}/scripts/doubao_web_archive.py" --days 30 >>"${LOG_DIR}/web_archive.log" 2>&1 || true</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>${HOUR}</integer><key>Minute</key><integer>${MINUTE}</integer></dict>
  <key>StandardOutPath</key><string>${LOG_DIR}/launchd.out</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/launchd.err</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
echo "已安装：每天 ${HOUR}:$(printf '%02d' "$MINUTE") 清理 + 归档 30 天前会话（label ${LABEL}）"
echo "查看状态: bash scripts/install_schedule.sh --status"
