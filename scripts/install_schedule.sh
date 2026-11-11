#!/usr/bin/env bash
# 安装 / 卸载 豆包定时清理（launchd LaunchAgent，清理后自动重启豆包）
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${HOME}/.local/share/doubao-cleaner"
LA_DIR="${HOME}/Library/LaunchAgents"
CLEANER_LABEL="com.hust.doubao-cleaner"
RESTART_LABEL="com.hust.doubao-restart"
UID_NUM="$(id -u)"

HOUR=4
MINUTE=10
ACTION="install"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hour) HOUR="$2"; shift 2 ;;
    --minute) MINUTE="$2"; shift 2 ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --status) ACTION="status"; shift ;;
    --run-now) ACTION="run-now"; shift ;;
    -h|--help)
      echo "用法: install_schedule.sh [--hour 4] [--minute 10] | --uninstall | --status | --run-now"
      exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

status() {
  echo "== LaunchAgents =="
  launchctl list 2>/dev/null | grep -E "doubao-(cleaner|restart)" || echo "未安装"
  [[ -f "${LA_DIR}/${CLEANER_LABEL}.plist" ]] && echo "plist: ${LA_DIR}/${CLEANER_LABEL}.plist"
}

uninstall() {
  launchctl bootout "gui/${UID_NUM}/${CLEANER_LABEL}" >/dev/null 2>&1 || true
  launchctl bootout "gui/${UID_NUM}/${RESTART_LABEL}" >/dev/null 2>&1 || true
  rm -f "${LA_DIR}/${CLEANER_LABEL}.plist" "${LA_DIR}/${RESTART_LABEL}.plist"
  echo "已移除定时清理任务（脚本目录 ${INSTALL_DIR} 保留，可手动执行）"
}

run_now() {
  launchctl kickstart -k "gui/${UID_NUM}/${CLEANER_LABEL}"
  echo "已触发一次清理（含重启），日志: ${HOME}/Library/Logs/doubao-cleaner/clean.log"
}

install() {
  mkdir -p "$INSTALL_DIR" "$LA_DIR"
  cp "${SKILL_DIR}/scripts/doubao_clean.sh" "${INSTALL_DIR}/"
  cp "${SKILL_DIR}/scripts/doubao_restart.sh" "${INSTALL_DIR}/"
  cp "${SKILL_DIR}/scripts/doubao_web_archive.py" "${INSTALL_DIR}/"
  chmod +x "${INSTALL_DIR}/doubao_clean.sh" "${INSTALL_DIR}/doubao_restart.sh" "${INSTALL_DIR}/doubao_web_archive.py"

  # 先卸旧再装新（幂等）
  launchctl bootout "gui/${UID_NUM}/${CLEANER_LABEL}" >/dev/null 2>&1 || true
  launchctl bootout "gui/${UID_NUM}/${RESTART_LABEL}" >/dev/null 2>&1 || true

  cat > "${LA_DIR}/${CLEANER_LABEL}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${CLEANER_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${INSTALL_DIR}/doubao_clean.sh</string>
    <string>--restart</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>${HOUR}</integer>
    <key>Minute</key><integer>${MINUTE}</integer>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/doubao-cleaner/launchd.out</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/doubao-cleaner/launchd.err</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF

  cat > "${LA_DIR}/${RESTART_LABEL}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${RESTART_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${INSTALL_DIR}/doubao_restart.sh</string>
  </array>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/doubao-cleaner/restart.out</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/doubao-cleaner/restart.err</string>
</dict>
</plist>
EOF

  launchctl bootstrap "gui/${UID_NUM}" "${LA_DIR}/${CLEANER_LABEL}.plist" 2>/dev/null || \
    launchctl load -w "${LA_DIR}/${CLEANER_LABEL}.plist"
  launchctl bootstrap "gui/${UID_NUM}" "${LA_DIR}/${RESTART_LABEL}.plist" 2>/dev/null || \
    launchctl load -w "${LA_DIR}/${RESTART_LABEL}.plist"

  echo "已安装：每天 ${HOUR}:$(printf '%02d' "$MINUTE") 自动归档网页版 7 天前会话 + 清理 + 重启豆包"
  echo "脚本目录: ${INSTALL_DIR}"
  echo "日志: ${HOME}/Library/Logs/doubao-cleaner/clean.log"
}

case "$ACTION" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  run-now) run_now ;;
esac
