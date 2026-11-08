#!/usr/bin/env bash
# 依赖安装：opencli 2.x（浏览器桥）+ Chrome 扩展指引
# 用法: bash scripts/install_deps.sh [--check]
set -euo pipefail

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

say() { printf '%s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

say "== doubao-chat-cleaner 依赖检查 =="

# 1) node / npm（opencli 是 npm 包；缺少就用 brew 装）
if ! have node || ! have npm; then
  say "未检测到 node/npm。"
  if have brew; then
    if [[ "$CHECK_ONLY" == "1" ]]; then
      say "[check] 需要: brew install node"
    else
      say "→ brew install node"
      brew install node
    fi
  else
    say "请先安装 Node.js（https://nodejs.org）或 Homebrew 后重试。"
    exit 1
  fi
fi

# 2) opencli
OPENCLI_BIN="$(command -v opencli || true)"
if [[ -z "$OPENCLI_BIN" ]]; then
  # 豆包桌面端自带的 opencli 也能用（sandbox_runtime 里），避免重复安装
  OPENCLI_BIN="$(ls "$HOME/Library/Application Support/Doubao"/sandbox_runtime/bases/*/bin/opencli 2>/dev/null | tail -1 || true)"
fi

if [[ -z "$OPENCLI_BIN" ]]; then
  if [[ "$CHECK_ONLY" == "1" ]]; then
    say "[check] 需要: npm install -g @jackwener/opencli"
  else
    say "→ npm install -g @jackwener/opencli"
    npm install -g @jackwener/opencli
  fi
else
  say "opencli: $OPENCLI_BIN ($("$OPENCLI_BIN" --version 2>/dev/null || echo '?') )"
fi

# 3) 浏览器桥自检
OPENCLI_BIN="${OPENCLI_BIN:-$(command -v opencli || true)}"
if [[ -n "${OPENCLI_BIN:-}" ]]; then
  say ""
  say "== opencli doctor =="
  "$OPENCLI_BIN" doctor 2>&1 | tail -5 || true
  say ""
  say "若看到 extensionConnected: false —— 需要装 Chrome 扩展 Browser Bridge："
  say "  1) 打开 https://github.com/jackwener/opencli/releases 下载最新扩展（.zip/.crx）"
  say "  2) Chrome → chrome://extensions → 打开「开发者模式」→ 加载已解压的扩展程序"
  say "  3) 回到终端跑：opencli doctor   （extensionConnected 变 true 即可）"
  say "  4) Chrome 里登录 https://www.doubao.com（归档/恢复要用你的登录态）"
  if [[ "$CHECK_ONLY" != "1" ]]; then
    [[ -d "/Applications/Google Chrome.app" ]] && open "https://github.com/jackwener/opencli/releases" || true
  fi
  say ""
  say "常见兜底：扩展连不上 → opencli daemon restart"
fi

say ""
say "完成。下一步：python3 scripts/doubao_web_restore.py --list"
