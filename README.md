# doubao-chat-cleaner

豆包（doubao.com / macOS 桌面端）会话清理工具：**本地缓存瘦身 + 网页版历史会话批量归档 + 已归档会话恢复**。
以一个可被 AI Agent 直接调用的 Skill 形式提供（Claude Code / Codex / 豆包等都能用），也可以纯命令行跑。

> 为什么需要它：豆包桌面端跑久了缓存和日志能堆到数 GB，网页端会话越攒越多（项目分组直接被历史会话挤满），
> 而网页端**没有**归档列表入口，批量归档、批量恢复都只能靠手动一条条点。

## 能力

| 能力 | 命令 | 说明 |
|---|---|---|
| 本地瘦身 | `bash scripts/clean_local.sh [--dry-run]` | 清 Python 沙箱缓存、滚动日志、Electron 缓存；旧会话工作区移到 `_archive/`（可回移） |
| 归档历史会话 | `python3 scripts/doubao_web_archive.py [--dry-run]` | 默认归档 **30 天前**的会话；年龄未知的**默认保留**，加 `--include-unknown` 才一并归档 |
| 撤销归档 | `python3 scripts/doubao_web_restore.py --project <项目名>` | 整项目恢复；`--conversation-id <id>` 单条恢复；`--list` 看各项目已归档条数 |
| 每日定时 | `bash scripts/install_schedule.sh` | launchd 每日定时清理 + 归档（默认 04:10） |
| 依赖安装 | `bash scripts/install_deps.sh` | 检查/安装 Node、opencli，并打印浏览器扩展安装指引 |

安全边界：**不动聊天内容本身，不动登录态**。归档 = 服务端置为归档态（数据仍在，可恢复）；恢复 = 取消归档。
唯一"删"的是可再生的缓存、滚动日志，以及你自己设置的 N 天前本地会话工作区（移进归档目录，不是删除）。

## 前置依赖

- macOS（本地清理部分仅支持 macOS；网页端归档/恢复在 Linux/Windows 上也可跑，前提是有 opencli + Chrome）
- Node.js 18+ / npm
- **opencli 2.x**：`npm install -g @jackwener/opencli`
- Chrome + opencli 的 **Browser Bridge 扩展**（从 [opencli releases](https://github.com/jackwener/opencli/releases) 下载，
  `chrome://extensions` 开发者模式「加载已解压的扩展程序」）
- Chrome 里**已登录 doubao.com**

一键检查：

```bash
bash scripts/install_deps.sh          # 缺什么装什么，并打印扩展安装步骤
bash scripts/install_deps.sh --check  # 只看缺什么
opencli doctor                        # 关键：extensionConnected 必须是 true
```

> 如果机器上装了豆包桌面端，它自带一份 opencli（`~/Library/Application Support/Doubao/sandbox_runtime/bases/*/bin/opencli`），
> 脚本会优先复用，无需重复安装。

## 快速开始

```bash
git clone https://github.com/<you>/doubao-chat-cleaner.git && cd doubao-chat-cleaner
bash scripts/install_deps.sh

bash scripts/clean_local.sh --dry-run                  # 看能清多少
python3 scripts/doubao_web_archive.py --dry-run        # 看会归档哪些会话
python3 scripts/doubao_web_archive.py --days 30        # 真归档
python3 scripts/doubao_web_restore.py --list           # 各项目已归档多少条
python3 scripts/doubao_web_restore.py --project newwork --dry-run
python3 scripts/doubao_web_restore.py --project newwork
```

## 它怎么工作（关键事实）

网页端没有公开 API，这里用的是页面自身在用的 `im` 接口，靠 opencli 在**你自己已登录的 Chrome** 里发请求，不碰 token：

| 用途 | 接口 | cmd | 关键参数 |
|---|---|---|---|
| 项目列表（含全部会话） | `POST /im/project/list` | 4605 | uplink 必须带 `{limit:N}`，传空对象报 `712010202 参数错误` |
| 会话状态 | `POST /im/conversation/batch_get` | 1111 | 返回 `conversation_info_list[].status`：**1=正常，8=已归档** |
| 归档 / 取消归档 | `POST /im/conversation/batch_operate` | 1125 | `operate_type: 8=归档、9=取消归档`；整项目传 `project_id`，单条传 `conversation_id_list` |

两个反直觉的点：

1. **项目清单里能看到 ≠ 没归档**。`project/list` 对已归档会话照样返回（带 `conversation_name`），而侧栏会显示"暂无对话"。
   判断归档与否只能看 `batch_get` 的 `status`。
2. **恢复后别指望台账自洽**。归档脚本用 `~/.local/share/doubao-chat-cleaner/web_archived.json` 去重，
   恢复脚本会把恢复的 id 写进 `web_keep.json` 白名单，否则下次定时任务会把它们又归档回去。

## 常见问题

- **`extensionConnected: false`**：扩展没装/没连上 → 装扩展后 `opencli daemon restart`。
- **归档了但侧栏还在**：极少数会话（系统通知类、老会话）接口返回 `success` 却不生效，属服务端行为。
- **归档后找不到会话**：用 `doubao_web_restore.py --list` 查项目，或直接访问 `https://www.doubao.com/chat/<会话id>`（已归档会话仍可打开）。
- **不想动网页端**：只跑 `clean_local.sh` 即可，两者互不依赖。

## License

MIT，见 [LICENSE](LICENSE)。
