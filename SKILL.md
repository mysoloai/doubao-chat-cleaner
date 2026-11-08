---
name: doubao-chat-cleaner
display_name: 豆包会话清理与归档
version: "1.0.0"
description: 清理豆包 macOS 桌面端缓存与日志、批量归档网页版(doubao.com)历史会话、把已归档会话恢复回来、可安装每日定时清理。触发词：「豆包卡顿」「豆包清理」「豆包瘦身」「清豆包缓存」「归档豆包会话」「归档三个月前的会话」「撤销归档」「恢复豆包会话」「把XX项目的会话恢复回来」「每天自动清理豆包」。不用于：整机磁盘清理（用通用磁盘清理技能）、豆包技能管理、账号与会员问题。
allowed-tools:
  - Bash
  - Read
---

# 豆包会话清理与归档

给豆包做"瘦身 + 会话管理"：清可再生的缓存/日志、把网页端历史会话批量归档、一键恢复归档的会话。

## Step 0（必做）：确认依赖，缺就让 Agent 自动装

```bash
bash scripts/install_deps.sh --check    # 先看缺什么
bash scripts/install_deps.sh            # 缺什么补什么
```

判据：`opencli doctor` 里 `extensionConnected: true`，且 Chrome 已登录 doubao.com。
缺扩展时**不要静默跳过**——按 `install_deps.sh` 打印的步骤引导用户装 Browser Bridge 扩展
（`https://github.com/jackwener/opencli/releases` → `chrome://extensions` → 开发者模式 → 加载已解压的扩展程序），
装完让用户回来跑 `opencli doctor` 复核。本地清理部分不需要 opencli，缺依赖时也能单独先做。

## Step 1：本地瘦身（先预演再动手）

```bash
bash scripts/clean_local.sh --dry-run          # 逐项报"可释放多少 MB"
bash scripts/clean_local.sh                    # 真清
bash scripts/clean_local.sh --gecko-cache      # 连网页内核缓存一起清
bash scripts/clean_local.sh --archive-session-days 30
```

汇报时必须说明是**预演**还是**实清**，并给出前后占用对比；不要承诺"清完就不卡了"（缓存只省磁盘）。

## Step 2：归档网页版历史会话

```bash
python3 scripts/doubao_web_archive.py --dry-run            # 默认 30 天口径
python3 scripts/doubao_web_archive.py --days 90
python3 scripts/doubao_web_archive.py --include-unknown    # 连年龄未知的一起归档
python3 scripts/doubao_web_archive.py --keep <会话id>      # 强制保留
```

**默认口径**：只归档 30 天前活跃的会话；**年龄未知的默认保留**（网页端接口不给时间，判断不了新旧就别动）。
用户明确要"都清掉"时再加 `--include-unknown`。

## Step 3：撤销归档（恢复会话）

```bash
python3 scripts/doubao_web_restore.py --list                        # 项目 + 各项目已归档条数
python3 scripts/doubao_web_restore.py --project <项目名> --dry-run
python3 scripts/doubao_web_restore.py --project <项目名>
python3 scripts/doubao_web_restore.py --conversation-id <id>        # 可重复
```

脚本内部：读项目清单 → `batch_get` 的 `status` 判归档态 → `batch_operate(operate_type=9)` → **回读 status 复核** → 写白名单。
恢复成功的判据是 `status` 从 8 变成 1，**不要**只看接口是否 `code:0`。

## Step 4（可选）：每日定时

```bash
bash scripts/install_schedule.sh --hour 4 --minute 10   # 每天 04:10 清理 + 归档
bash scripts/install_schedule.sh --status
bash scripts/install_schedule.sh --run-now
bash scripts/install_schedule.sh --uninstall
```

用 launchd 而不是平台定时任务——清理脚本会重启/占住豆包，平台定时任务跑在豆包进程里会被自己杀掉。

## 数据与文件

| 路径 | 内容 |
|---|---|
| `~/.local/share/doubao-chat-cleaner/web_archived.json` | 归档台账（去重，防止对已归档会话反复提交） |
| `~/.local/share/doubao-chat-cleaner/web_keep.json` | 白名单：恢复过/想保留的会话，定时任务跳过 |
| `~/Library/Logs/doubao-chat-cleaner/*.log` | 清理、归档、恢复日志 |
| `~/Library/Application Support/Doubao/_archive/sessions-YYYY-MM-DD/` | 本地旧会话工作区归档（含 manifest.tsv） |

## Gotchas

- **项目清单里能看到会话 ≠ 没归档**：`/im/project/list`（cmd 4605）对已归档会话照样返回，侧栏却显示"暂无对话"；
  uplink 必须带 `{limit:N}`，传空对象直接 `712010202 参数错误`。
- **归档态判定只有一条可靠口径**：`/im/conversation/batch_get`（cmd 1111）的 `status`，1=正常、8=已归档。
- **恢复后必须写白名单**：否则下次归档任务会把刚恢复的会话又收回去。
- **会话历史很深**：清掉一屏立刻补进更早的一屏，单轮只挖得到 10–20 条；归档脚本支持 `--limit`/多轮跑。
- **少数会话接口假成功**（系统通知类）：`success:true` 但侧栏照旧，属服务端行为，不必反复重试。
- **本地清理别碰**：`Default/IndexedDB`、`Local Storage`（聊天记录与登录态）、`.doubao/agent_mode/workspace`（技能与经验）、`hot_fix`、`coding`。
- **网页端无归档列表入口**：`/chat/archive` 打不开；想看/恢复归档会话只能用本仓库的 `restore --list`，或直访 `https://www.doubao.com/chat/<会话id>`。
