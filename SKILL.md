---
name: doubao-cleaner
display_name: 豆包清理瘦身
version: "1.3.0"
description: 清理豆包 Mac 桌面端缓存与历史日志、归档 N 天前的会话（本地工作区 + 网页版 doubao.com）、把已归档会话恢复回来，可清理后重启豆包，并安装每日定时自动清理。触发词：「豆包卡顿」「豆包清理」「豆包瘦身」「清豆包缓存」「豆包重启」「归档豆包会话」「归档一周前的对话」「撤销归档」「恢复豆包会话」「把XX项目的会话恢复回来」「每天清理豆包」「定时清理豆包」。不用于：整台电脑清理/磁盘空间不足（用 doubao-pc-optimizer）、豆包技能管理（doubao-skill-manager）、豆包会员与账号问题（doubao-identity）。
allowed-tools:
  - Bash
  - Read
---

# 豆包清理瘦身

在 macOS 上给豆包做可逆的瘦身：清缓存日志、归档旧会话（桌面端工作区 + 网页版对话），支持「清理后重启豆包」与每日定时执行。

## 前置依赖

- macOS + 已安装豆包桌面端（`/Applications/Doubao.app`）
- `bash`、`launchctl`、`osascript`、`python3`（系统自带）
- **网页版归档额外依赖 opencli 2.x**：可执行文件在
  `<豆包数据目录>/sandbox_runtime/bases/*/bin/opencli`，且 Chrome 的 Browser Bridge 需连通
  （`opencli doctor` 为绿），浏览器已登录 doubao.com。取不到就只做本地清理，不阻塞。

## 触发场景

- 「豆包好卡 / 豆包很卡顿，帮我清一下」「清理豆包缓存」「豆包瘦身」
- 「清理完帮我重启豆包」「每天凌晨自动清理豆包」
- 「把豆包的历史会话归档」「只归档一周以前的对话」
- 「把 XX 项目的会话撤销归档」「恢复我上周归档的对话」

## 不触发场景

- 整机磁盘满、开机慢 → `doubao-pc-optimizer`
- 豆包个人技能的增删 → `doubao-skill-manager`
- 卸载豆包、登录、会员付费 → 对应技能

## 执行步骤

### Step 1：预演（默认先看，不动文件）

```bash
bash scripts/doubao_clean.sh --dry-run
```

输出每项的「可释放容量」+ 网页版待归档会话数量，先让用户看数字。

### Step 2：实际清理

```bash
bash scripts/doubao_clean.sh                    # 归档 7 天前会话 + 清缓存
bash scripts/doubao_clean.sh --web-archive-days 30   # 网页版改只归档 30 天前
bash scripts/doubao_clean.sh --archive-session-days 30 # 本地工作区改 30 天
bash scripts/doubao_clean.sh --no-web-archive   # 只清本地，不碰网页版
```

### Step 3：（可选）清理后重启豆包

```bash
bash scripts/doubao_clean.sh --restart
```

**在豆包会话内调用时**，脚本会自动把重启委托给 launchd（`com.hust.doubao-restart`），否则退出豆包会把执行清理的进程一起杀掉、重启不了。前提是 Step 4 已装过定时任务。

### Step 4：安装每日定时清理

```bash
bash scripts/install_schedule.sh --hour 4 --minute 10   # 默认每天 04:10
bash scripts/install_schedule.sh --status
bash scripts/install_schedule.sh --run-now              # 立即跑一次（含重启）
bash scripts/install_schedule.sh --uninstall
```

- 定时任务由 **launchd** 驱动，不依赖豆包是否在运行，也**不受豆包重启影响**——这是关键：用平台「定时任务」跑清理再重启，会把自己的会话杀掉。
- 脚本会复制到 `~/.local/share/doubao-cleaner/`，定时任务指向该稳定路径。
- 每天固定执行：「网页版归档 7 天前会话（失败跳过）→ 清缓存 → 重启豆包」。

### 单独归档网页版会话（不清理时也可以）

```bash
python3 scripts/doubao_web_archive.py --dry-run          # 只看会归档哪些
python3 scripts/doubao_web_archive.py                    # 归档 7 天前的
python3 scripts/doubao_web_archive.py --days 30
python3 scripts/doubao_web_archive.py --keep <会话id>    # 强制保留某些会话
python3 scripts/doubao_web_archive.py --keep-unknown     # 保留年龄未知的会话
```

### 撤销归档（把已归档的会话恢复回来）

```bash
python3 scripts/doubao_web_restore.py --list                        # 列项目 + 每个项目已归档条数
python3 scripts/doubao_web_restore.py --project newwork --dry-run   # 看将恢复哪些（不动手）
python3 scripts/doubao_web_restore.py --project newwork             # 整个项目恢复
python3 scripts/doubao_web_restore.py --conversation-id <id>        # 单条恢复（可重复）
python3 scripts/doubao_web_restore.py --project newwork --no-keep   # 不写白名单
```

脚本做的事：读项目清单 → 用 `batch_get` 的 `status` 判哪些是归档态（1=正常 / 8=已归档）→ 调 `batch_operate`（`operate_type: 9`，整项目传 `project_id`、单条传 `conversation_id_list`）→ **回读 status 复核**是否为 1 → 把恢复成功的 id 写进白名单 `web_keep.json`。

原理与坑（改脚本前必读）：

- 同一个接口 `batch_operate`（cmd 1125）换 `operate_type` 即反向：**8 = 归档，9 = 取消归档**；单条恢复时 `project_id` 传空字符串也能成功（实测）。
- 项目会话清单走 `POST /im/project/list`（cmd 4605），uplink 必须带 `{limit:N}`（**传空对象报 `712010202 参数错误`**）；返回的 `projects[].conversations` 含该项目**全部**会话，已归档的也在其中，且带 `conversation_name`/`create_time`/`update_time`。
- 归档状态只看 `POST /im/conversation/batch_get`（cmd 1111）→ `conversation_info_list[].status`：`1` 正常、`8` 归档。**这是唯一可靠的接口级判据**，比读侧栏稳。
- 侧栏可做二次确认：恢复后对应项目从「暂无对话」变回挂出会话。
- 恢复后**不要**把 id 从 `web_archived.json` 删掉就完事，那会让次日定时任务重新归档它；脚本已自动写进 `web_keep.json` 的 `ids` 数组（启动时并入 `--keep`）。

## 清理与归档范围

| 项目 | 默认行为 |
|---|---|
| 本地会话工作区 `.sessions/*` | 超过 **7 天**未活动 → 移到 `_archive/sessions-YYYY-MM-DD`（`--archive-session-days` 可调） |
| 网页版 doubao.com 历史会话 | 超过 **7 天**未活动 → 调 `batch_operate`（`operate_type: 8`）归档（`--web-archive-days` 可调）；年龄未知的默认一并归档 |
| `sandbox_runtime/.cache/python` | 清（有进程占用时跳过） |
| `sdk_storage/log/*.log`、`*.alaudalog` | 清，默认只留当天（`--keep-log-days` 可调） |
| `Caches/Doubao/Default/{Cache,Code Cache,GPUCache}` | 清 |
| `gecko_cache` | 默认**不清**，加 `--gecko-cache` 才清 |
| 本地归档区超过 120 天的批次 | 删（`--keep-archive-days` 可调） |

**绝对不动**：`Default/IndexedDB`、`Local Storage`（聊天记录 + 登录态）、`.doubao/agent_mode/workspace` 下的技能与经验、`hot_fix`、`coding`、任何用户个人文件；**置顶会话永不归档**。

## 网页版归档的年龄判定（重要）

网页端接口不直接暴露会话时间，脚本按以下顺序取「最后活跃时间」：

1. 本地工作区目录 `.../workspace/.sessions/<会话id>` 的 mtime（桌面端用过的会话都有，最可信）
2. `_archive/sessions-*/manifest.tsv` 的 `last_modified`
3. 两者都没有 → **年龄未知，默认一并归档**（用户已确认此口径）；要保留就加 `--keep-unknown`

注意：纯网页端新建、桌面端从未打开过的会话属于"未知"这一类，默认会被归档（无法从时间上区分新旧）。

## 异常处理

- **网页版归档被跳过**：看 `~/Library/Logs/doubao-cleaner/web_archive.log`。最常见是 opencli 未连通（`opencli doctor` 里 `extensionConnected: false` → `opencli daemon restart`），或 Chrome 没开。
- **清理后仍卡**：清理只省磁盘，不等于治卡顿；按实际证据说明（单个渲染进程内存、会话数量），别承诺"清完就不卡了"。
- **重启后报「委托重启失败」**：LaunchAgent 没装，用 `install_schedule.sh` 装好再试。
- **定时任务没跑**：`launchctl list | grep doubao-cleaner` 看状态码，再看 `~/Library/Logs/doubao-cleaner/launchd.err`。

## Gotchas

- **网页版归档必须在重启豆包之前执行**：opencli 装在豆包的 `sandbox_runtime` 里，豆包一重启，opencli 的 daemon 跟着没了。`doubao_clean.sh` 已把归档放在第 0 步。
- **不要在豆包会话里直接 `osascript quit` + `open -a` 重启**：会先杀掉自己，后面的 `open` 根本不执行。必须走 launchd 委托。
- **侧栏会话是"点按钮才加载"的**：滚动和 WheelEvent 都不触发懒加载，必须点「展开更多对话 / 展开更多项目」，且该按钮在 `project-grouped-section` 下，不在 `conversation-section` 里。
- **归档判定不能只看接口返回**：接口对已归档的 id 仍返回 `success`（幂等空转），必须每轮刷新页面再用 DOM 复核，否则会反复"成功"同一批。
- **接口对少数会话报成功但其实没归档**（实测：`服务通知` 这类系统会话、以及部分老会话，`success:true` 后侧栏照旧）。这类只能走界面：`open https://www.doubao.com/chat/<id>` → `click --testid conversation_header_more_button` → `click --role menuitem --name "归档"`，归档后侧栏立即消失（toast「已归档对话，你可以撤销」）。
- **跑到底要用 `scripts/doubao_web_archive_all.sh`**：每轮侧栏只渲染 ~10 条（其中约 6 条可归档），清掉后立刻补进更早的一页，单跑一次脚本挖不到底。驱动脚本反复调用直到无进展（`bash scripts/doubao_web_archive_all.sh 7`，第二参数是最大轮数）。
- **渲染等待 4s 够用**：从 7s 降到 4s、展开轮次 8 降到 3，实测采集条数不变、单轮耗时 34s→16s。
- **会话历史可能极深**：清掉一屏立刻补进更早的一屏（id 单调变老），单次脚本只挖得到 10–20 条。`doubao_clean.sh` 因此默认跑 `WEB_ARCHIVE_PASSES=10` 轮（`--web-archive-passes` 可调），逐日往下推。
- **接口对已归档 id 仍返回 success**：脚本用 `~/.local/share/doubao-cleaner/web_archived.json` 记台账，已归档过的（哪怕仍显示）不再重复提交，否则会每轮空转同一批。
- **网页版没有归档列表入口**：`/chat/archive` 打不开归档列表，账号菜单里也没有；但**接口能反向恢复**（`scripts/doubao_web_restore.py`，或单条走界面：已归档会话仍能 `open https://www.doubao.com/chat/<id>`，头部 `conversation_header_more_button` 菜单里有「取消归档 ⇧⌘H」）。
- **别把「项目列表里能看到」当成「没归档」**：项目清单接口对已归档会话照样返回（侧栏却是「暂无对话」），判断归档与否必须看 `batch_get` 的 `status`。
- `du -sh <dir>/*` 会漏掉隐藏点目录（如 `sandbox_runtime/.cache`，实测 3.9G），审计体积必须补 `.*`。
- 每日日志单日可达 130MB+，只留当天就够。
- `--dry-run` 只统计不删除，汇报时必须说明「预演/实删」，别让用户误以为已经清理了。
