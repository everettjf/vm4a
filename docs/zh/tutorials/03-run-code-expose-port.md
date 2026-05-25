---
title: 3 · run-code 与 expose-port
layout: default
parent: 教程
grand_parent: 中文文档
nav_order: 3
description: "一次调用跑代码片段；为 guest 端口解析出主机可访问的 URL。"
---

# run-code 与 expose-port
{: .no_toc }

**目标：** 不用 `cp`+`exec` 两步就跑一段代码；从你的 Mac 访问 guest 里跑着的服务。
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## run-code —— 一次调用跑片段

`run-code` 把你的源码写到 guest 里一个私有临时文件，用对应解释器运行，再删掉 —— 替代手动的 `cp` + `exec`。

```bash
vm4a run-code /tmp/vm4a/dev --lang python --code 'print(1 + 1)'
vm4a run-code /tmp/vm4a/dev --lang node   --file ./script.js --output json
```

支持的语言映射到 `python3`、`node`、`bash`、`sh`、`ruby`。`--code` / `--file` 只传其中一个。

返回和 `exec` 一样的结构：

```bash
vm4a run-code /tmp/vm4a/dev --lang python --code 'print("hi")' --output json
# → {"exit_code":0,"stdout":"hi\n","stderr":"","duration_ms":210,"timed_out":false}
```

退出码会传递，所以能在 shell 里组合：

```bash
if vm4a run-code /tmp/vm4a/dev --lang bash --code 'test -f /etc/os-release'; then
  echo "存在"
fi
```

{: .note }
> 校验在任何 SSH 之前发生：未知的 `--lang`、或同时传/都不传 `--code` 与 `--file`，都会立刻带清晰提示失败。

## expose-port —— 访问 guest 服务

NAT guest 在主机侧本来就能用其 DHCP 租约 IP 直连，所以"暴露"端口只是解析那个 IP 再拼成 URL —— 不开隧道、不起转发 daemon。

```bash
# 通过 run-code 在 guest 里后台起一个服务：
vm4a run-code /tmp/vm4a/dev --lang bash --code 'nohup python3 -m http.server 8000 >/tmp/srv.log 2>&1 &'

# 解析主机可访问的 URL：
vm4a expose-port /tmp/vm4a/dev --port 8000
# → http://192.168.64.7:8000

# 现在从你的 Mac curl 它：
curl -s "$(vm4a expose-port /tmp/vm4a/dev --port 8000)" | head
```

JSON 和自定义 scheme：

```bash
vm4a expose-port /tmp/vm4a/dev --port 443 --scheme https --output json
# → {"url":"https://192.168.64.7:443","host":"192.168.64.7","port":443,"scheme":"https"}
```

### bridged VM：`--host`

bridged guest 拿不到 Apple DHCP 租约，所以自己传地址。带 `--host` 时，`expose-port` 完全跳过 DHCP 查询 —— 甚至不需要 bundle：

```bash
vm4a expose-port /tmp/vm4a/dev --port 8000 --host 10.0.0.42
```

## 你学到了什么

- `run-code` 把 `cp`+`exec` 合成一次调用，覆盖 `python`/`node`/`bash`/`sh`/`ruby`。
- `expose-port` 把 guest 端口变成主机可访问 URL，无需隧道。
- `--host` 让 `expose-port` 适用于 bridged VM（且不需要 bundle）。

**下一篇：** [MCP 接入](04-mcp) —— 把这些作为工具交给 AI 助手。
