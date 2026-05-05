# VM4A 用例集

按真实 workload 整理的端到端方案。每个条目都包含问题描述、架构、完整命令、取舍分析。

> English: [README.md](README.md)

| 用例 | 简介 |
|---|---|
| [`golden-image-with-parallel-forks.md`](golden-image-with-parallel-forks.md) | 装好 Python + 克隆大仓库的 base VM，做快照，cron 每日刷新，按需 fork 出隔离的并行实例给 Agent 任务用 |

如果你的 workload 不在这些里，欢迎开 issue 或 PR 加 recipe。Cookbook（[`Cookbook.md`](../Cookbook.md)）放的是单条命令的 how-to；这个目录放的是完整场景的方案。
