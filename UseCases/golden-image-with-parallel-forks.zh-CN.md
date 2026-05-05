# Golden Image + 每日刷新 + 并行 ephemeral fork

> English: [golden-image-with-parallel-forks.md](golden-image-with-parallel-forks.md)

## 问题

你在搭一个 agent 系统，每个任务都需要：

- 装好特定版本的 Python（或 Xcode、或别的工具链）
- 一个或多个大仓库（~1 GB+）的可用副本
- 仓库保持基本最新（昨天的 `git pull`，不是上个月的）
- 并行任务之间严格隔离 —— 一个任务的 `rm -rf /` 不能影响其他任务
- 取一台 VM 要快 —— agent 不应该每个任务都等 `apt-get install` 或 `git clone`

直觉解法都跑不通：

- **直接在 host 上跑**：没隔离，一个坏 agent 就把你机器搞坏
- **每个任务起一台全新 Linux VM**：隔离 ✓，但装 + clone 5–15 分钟，一个任务的时长够你喝杯咖啡
- **共享磁盘缓存安装结果**：隔离 ✗，`/repos` 上互相打架
- **一个长跑 VM，任务之间 `git pull`**：隔离 ✗，状态在任务间泄漏

你真正想要的是 **快速克隆一个已知干净的镜像，每个克隆是独立机器**。这正是 VM4A 的 golden-image + per-task fork 模式。

## 目标

- 一次性 bootstrap，之后可重复
- 每日刷新分钟级，不是小时级
- 每个任务的 spawn 是**秒级**（warm 路径）或 **<30 秒**（冷启动）
- 每个任务有自己的文件系统、内核、网络
- N 个并行任务运行时零状态共享
- Linux guest 全自动；macOS guest 第一次需要点一次 Setup Assistant

## 不是目标

- 没有 daemon 的亚秒级出库（warm pool 能做到，纯 fork 即使带 `--from-snapshot` 也是约 1 秒，冷启动约 30 秒）
- 跨机器分发（用 `vm4a push` / `vm4a pull` 到 registry，独立的关注点，已经完整支持）
- 容器；这里用的是完整 VM，因为 agent 隔离是安全边界，不只是打包便利

## 架构

```
                          (cron, 每天)
                                │
                                ▼
        ┌───────────────────────────────────────────┐
        │  Base bundle: /tmp/vm4a/base              │
        │   - Disk.img（装好 Python + repos）        │
        │   - latest.vzstate → today.vzstate        │
        │   - 历史: v1.vzstate, 20260501.vzstate, … │
        └───────────────────────────────────────────┘
                                │
                  vm4a fork --keep-identity --from-snapshot
                                │
       ┌────────────────────────┼────────────────────────┐
       ▼                        ▼                        ▼
  task-1234（运行中）        task-1235（运行中）       task-1236（运行中）
   独立 Disk.img             独立 Disk.img            独立 Disk.img
   独立 MAC                  独立 MAC                 独立 MAC
   共享 platform ID          共享 platform ID         共享 platform ID
   （让 .vzstate             （让 .vzstate            （让 .vzstate
    restore 能成功）          restore 能成功）         restore 能成功）
```

三个关键点让这个架构成立：

1. **APFS clonefile** —— 克隆 bundle 是 O(目录条目数)，不是 O(磁盘大小)。100 GB bundle 毫秒级克隆完。
2. **VZ 内存快照（`.vzstate`）** —— 保存的内存状态让 fork 一秒内恢复，省掉冷启动。快照配合克隆磁盘工作，因为快照保存时磁盘就是那个磁盘。
3. **`--keep-identity`** —— `MachineIdentifier` 是 VZ 平台标识，快照恢复时会校验。fork 必须保留源的标识；fork 的隔离来自克隆磁盘和独立 MAC（这两个和 platform identity 无关）。

## 一步步走

### 0. 选 OS

| | Linux | macOS |
|---|---|---|
| 第一次设置 | 全自动（cloud-init 或手动 ssh） | 每个新 IPSW 一次 Setup Assistant 点击 |
| 之后重建 | 全自动 | 全自动 |
| 推荐 | 默认。除非你确实需要 macOS 工具链（Xcode、签名、App Store 构建），否则用这个 | Agent 需要编译/测试 iOS/macOS app 时用 |

下面用 Linux 写示例。macOS 在第 4 步开始完全一致；区别在文末单独说。

### 1. Bootstrap base VM（一次性）

```bash
BASE=/tmp/vm4a/base

vm4a spawn base \
    --image ubuntu-24.04-arm64 \
    --storage /tmp/vm4a \
    --memory-gb 8 --disk-gb 100 \
    --wait-ssh
```

`--image ubuntu-24.04-arm64` 是 catalog id；`vm4a` 第一次用时自动下载 ISO 到 `~/.cache/vm4a/images/`。SSH 起来后装工具链 + clone 仓库：

```bash
vm4a exec $BASE -- bash -lc '
    set -euo pipefail
    apt-get update -qq
    apt-get install -y -qq curl git build-essential
    curl -fsSL https://pyenv.run | bash
    export PATH="$HOME/.pyenv/bin:$PATH"
    eval "$(pyenv init -)"
    pyenv install 3.12 && pyenv global 3.12
    mkdir -p /repos && cd /repos
    git clone --depth=1 https://github.com/yourorg/repo-a.git
    git clone --depth=1 https://github.com/yourorg/repo-b.git
'
```

### 2. 存第一个快照

```bash
# 用 --save-on-stop 武装运行中的 VM，再 stop 触发存盘
vm4a stop $BASE
vm4a run $BASE --save-on-stop $BASE/v1.vzstate
sleep 30
vm4a stop $BASE

# 软链 "latest"，下游不用知道日期后缀
ln -sf v1.vzstate $BASE/latest.vzstate
```

软链是关键技巧 —— 让每日刷新可以原子切换"当前快照"，下游消费者无感。

### 3. 每日刷新（cron）

写个小 wrapper，比如 `~/bin/vm4a-refresh-base`：

```bash
#!/usr/bin/env bash
set -euo pipefail
BASE=/tmp/vm4a/base
TODAY=$BASE/$(date -u +%Y%m%d).vzstate

# 从昨天的快照 restore，pull，存今天的快照
vm4a run $BASE --restore $BASE/latest.vzstate --save-on-stop $TODAY
sleep 10
vm4a exec $BASE --timeout 1800 -- bash -lc '
    set -euo pipefail
    cd /repos
    for r in */; do
        echo "=== updating $r ==="
        (cd "$r" && git fetch --all --prune && git pull --rebase)
    done
'
vm4a stop $BASE

# 原子切换
ln -sfn "$(basename "$TODAY")" $BASE/latest.vzstate

# GC：删除 30 天前的快照
find $BASE -name '20*.vzstate' -mtime +30 -delete
```

cron 项：

```
30 3 * * *   /Users/me/bin/vm4a-refresh-base 2>&1 | logger -t vm4a-refresh
```

如果刷新失败（`git pull` 冲突、断网、磁盘满），cron 非 0 退出，`latest.vzstate` 还指向昨天的快照 —— agent 用稍微旧一点的仓库，不至于完全没有。

### 4. 每个任务 fork（agent 的热路径）

```bash
JOB=task-$(date +%s)-$RANDOM
DST=/tmp/vm4a/$JOB

vm4a fork $BASE $DST \
    --auto-start \
    --from-snapshot $BASE/latest.vzstate \
    --keep-identity \
    --wait-ssh

# 跑 agent step
vm4a exec $DST --output json --timeout 600 \
    -- python3 /repos/repo-a/scripts/agent_step.py "$@"

# 完成 —— 清理
vm4a stop $DST
rm -rf $DST
```

100 GB bundle 的端到端时间：
- `vm4a fork`（APFS clonefile）：~100 ms
- VM 从 `.vzstate` 恢复：~500 ms
- SSH 就绪：再 ~1–2 秒
- 总计：**2–3 秒** 从冷态到"可以跑代码"

> **关键：必须带 `--keep-identity`。** 不带它，`vm4a fork` 会重新随机化 `MachineIdentifier`，后续 `--from-snapshot` 恢复会被 VZ 拒掉（保存的状态绑定到原来的平台标识）。网络 MAC 是独立的 —— VZ 自动给每个 fork 生成独立 MAC，所以 NAT DHCP 还是给并行 fork 分不同 IP。

### 5. 并行扩展 —— 预热池

第 4 步对大多数 workload 已经够快，但如果你每分钟 spawn 几十个任务，2 秒也累。预热池 daemon 提前 spawn N 个 fork，acquire 是毫秒级文件 rename：

```bash
# 一次性定义池
vm4a pool create py \
    --base $BASE \
    --snapshot $BASE/latest.vzstate \
    --prefix task \
    --storage /tmp/vm4a-tasks \
    --size 4

# 起 daemon（前台运行；重启安全）
vm4a pool serve py &

# 每个任务：acquire（即时）、exec、release
VM=$(vm4a pool acquire py --output json | jq -r .path)
vm4a exec "$VM" --output json -- python3 /repos/repo-a/scripts/agent_step.py
vm4a pool release "$VM"
# daemon 下次 tick（默认 5s）发现少了一台，自动补
```

`vm4a pool serve` 在池定义里有 `--snapshot` 时**自动**带 `--keep-identity`，不用你额外操心。

## 运维考虑

### 磁盘占用

- `Disk.img` 按 `--disk-gb`（默认 64 GB）分配。APFS clonefile 让每个 fork 的磁盘**初始**不占额外空间（和源共享 block），但 guest 写入会分配新 block。100 GB base + 10 个 fork 各写 5 GB = 100 + 50 = 150 GB，不是 1 TB。
- `.vzstate` 快照大约等于 VM 内存大小（`--memory-gb 8` 就是 ~8 GB）。保留 7–30 天的日期快照用于回溯，cron 里 GC 掉旧的。
- 磁盘紧张：缩内存（快照变小），或者每日刷新后立刻删旧快照（只留 latest 软链指向的那个）。

### 快照健康度监控

每日刷新是最容易出问题的环节。建议加监控：

```bash
# cron wrapper 里：
START=$(date +%s)
... 主流程 ...
END=$(date +%s)
DURATION=$((END - START))
echo "vm4a-refresh: ok, ${DURATION}s, snapshot=$(readlink $BASE/latest.vzstate)"
```

接到你的告警系统（Slack webhook、Datadog、什么都行）。超过 30 分钟、cron 非 0 退出、或 `latest.vzstate` 超过 36 小时没更新就告警。

### 仓库层面的坑

- **`git pull` 合并冲突**：刚 clone 的仓库基本不会有，除非你预先 commit 了本地改动。保证 base VM 里的 working tree 干净，用 `git pull --rebase`（脚本里这么做的），考虑 `git pull --ff-only` 让冲突立刻失败。
- **带 submodule 的仓库**：循环里加 `git submodule update --init --recursive`。
- **LFS 仓库**：base 里装 `git-lfs`，pull 之后 `git lfs pull`。

### Fork 生命周期

- **僵尸 fork** 会累积，如果你的任务包装器没在出错时调 `vm4a stop` + `rm -rf`。shell 用 `trap`，Python 用 context manager，或者直接用 pool 的 `pool release`（一定清理）。
- **Pool 取空**：如果 `pool acquire` 比 `pool serve` 补得快，acquire 会阻塞到有 warm VM 为止。daemon 的 `--interval` 控制 scan 频率。

## 变体

### Linux + autoinstall（全自动 bootstrap）

第 1 步不走交互式安装，做一份 `user-data` cloud-init seed 配 ISO。超出本文范围；见 [Ubuntu autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/intro-to-autoinstall.html)。原则是"第 1 步也能 cron 化"，全新机器一个脚本从零重建。

### macOS guest（带一次 Setup Assistant）

```bash
# 第 1 步变了：
vm4a create base --os macOS --memory-gb 8 --disk-gb 100
# ... 自动拉最新 IPSW + 跑 VZMacOSInstaller（10–20 分钟）

# 然后打开 VM4A.app，过一次 Setup Assistant：
#   选区域 → 跳过 Apple ID → 建用户 `vm4a` → 进桌面
#   系统设置 → 通用 → 共享 → 远程登录：开
# 关掉 VM。

# 第 1 步（继续）—— 和 Linux 一样，只是 --user vm4a：
vm4a run base
sleep 30
vm4a exec base --user vm4a -- bash -lc '
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
    brew install pyenv git
    pyenv install 3.12 && pyenv global 3.12
    mkdir -p /Users/vm4a/repos && cd /Users/vm4a/repos
    git clone https://github.com/yourorg/repo-a.git
'

# 第 2–5 步：和 Linux 一模一样（每个 exec 记得带 --user vm4a）
```

过了 Setup Assistant 后存的快照拿出来，每日刷新和每任务 fork 都是全自动的，无人工。把这个快照推到 GHCR 一次，别的开发者 `vm4a spawn dev --from <ref> --os macOS` 就完全跳过 Setup Assistant。

### 预制镜像分发（团队 / CI）

不用每个开发者都跑第 1 步，把 bootstrap 完的 base 推到 registry：

```bash
# 一次性
vm4a push $BASE ghcr.io/yourorg/agent-base:py3.12-2026-05-04

# 每个开发者机器 / CI runner
vm4a spawn base --from ghcr.io/yourorg/agent-base:py3.12-latest \
    --storage /tmp/vm4a --wait-ssh
# 第 2–5 步照常
```

registry 是真理之源；cron 每周或按需重建 + 重推。

### "我还不信任 `--keep-identity`"

跳过 `--keep-identity`（连带跳过 `--from-snapshot`），让每个 fork 从克隆的磁盘冷启动：

```bash
vm4a fork $BASE $DST --auto-start --wait-ssh
```

Linux 磁盘已经装好 Python + repos，冷启动 10–30 秒。比快照恢复慢，但绕开 VZ 标识匹配的任何细节问题。哪台 host 上快照 fork 出问题就当 fallback 用。

## 取舍

| 决定 | 优点 | 代价 |
|---|---|---|
| 快照 fork（`--from-snapshot --keep-identity`） | 每任务 <2 秒 | 依赖 VZ 在 platform ID 复用情况下能 restore；目前测试通过，但比冷启动 fork 走的路少 |
| 冷启动 fork（不带快照） | 最稳 | 每任务 10–30 秒 |
| 预热池（`pool serve`） | 出库毫秒级 | daemon 要常驻；不用也占 N 台 VM 的 RAM（`--memory-gb × N`） |
| 每日快照 vs 每小时 | 便宜、简单 | 任务可能用 1 天前的 commit |
| 30 天快照保留 | 容易回溯 | `8 GB × 30 = 240 GB` per pool |

## 为什么是 VM4A（vs 其他方案）

- **vs Docker / 容器**：容器和 host 共享内核，恶意 agent 代码可能逃逸。VM 是硬件边界。
- **vs UTM / VirtualBuddy**：那些工具没暴露可让 CLI 驱动的快照+fork 原语。
- **vs Tart**：类似的 Apple Silicon 原生工具；vm4a 在这里的差异化是 MCP/HTTP/SDK 接入面、Python SDK、warm-pool runtime，以及（重要的）对 `--keep-identity` 这种细节把话说清楚。
- **vs 云沙盒（E2B、Modal）**：那些只支持 Linux 且不在本地。需要 macOS guest，只有本地 Apple Silicon host VM 能行。

## 另见

- [`Cookbook.md`](../Cookbook.md) —— 单命令参考和短 recipe
- [`Usage.md`](../Usage.md) —— CLI 完整 flag 参考
- `vm4a fork --help`、`vm4a pool --help`、`vm4a image --help`
