# VM4A Use Cases

Concrete, end-to-end recipes for real workloads. Each entry walks through the problem, the architecture, the exact commands, and the tradeoffs.

> 中文：[README.zh-CN.md](README.zh-CN.md)

| Use case | Summary |
|---|---|
| [`golden-image-with-parallel-forks.md`](golden-image-with-parallel-forks.md) | Build a base VM with Python + large repos, snapshot it, refresh daily via cron, and spawn isolated parallel forks per agent task |

If you have a workload that doesn't fit any of these — open an issue or a PR with the recipe. The cookbook ([`Cookbook.md`](../Cookbook.md)) is for one-off commands; this directory is for full scenarios.
