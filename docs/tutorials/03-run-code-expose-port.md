---
title: 3 · run-code & expose-port
layout: default
parent: Tutorials
nav_order: 3
description: "Run a snippet in one call; resolve a host-reachable URL for a guest port."
---

# run-code & expose-port
{: .no_toc }

**Goal:** execute a snippet without the `cp`+`exec` dance, and reach a service running in the guest from your Mac.
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## run-code — a snippet in one call

`run-code` writes your source to a private temp file in the guest, runs it with the matching interpreter, and removes it — replacing a manual `cp` + `exec`.

```bash
vm4a run-code /tmp/vm4a/dev --lang python --code 'print(1 + 1)'
vm4a run-code /tmp/vm4a/dev --lang node   --file ./script.js --output json
```

Supported languages map to `python3`, `node`, `bash`, `sh`, `ruby`. Pass exactly one of `--code` / `--file`.

It returns the same shape as `exec`:

```bash
vm4a run-code /tmp/vm4a/dev --lang python --code 'print("hi")' --output json
# → {"exit_code":0,"stdout":"hi\n","stderr":"","duration_ms":210,"timed_out":false}
```

The exit code propagates, so it composes in shell:

```bash
if vm4a run-code /tmp/vm4a/dev --lang bash --code 'test -f /etc/os-release'; then
  echo "present"
fi
```

{: .note }
> Validation happens before any SSH: an unknown `--lang`, or passing both/neither `--code` and `--file`, fails fast with a clear message.

## expose-port — reach a guest service

NAT guests are routable from the host on their DHCP-leased IP, so "exposing" a port is just resolving that IP and formatting a URL — no tunnel, no forwarding daemon.

```bash
# Start a server in the guest (backgrounded), via run-code:
vm4a run-code /tmp/vm4a/dev --lang bash --code 'nohup python3 -m http.server 8000 >/tmp/srv.log 2>&1 &'

# Resolve the host-reachable URL:
vm4a expose-port /tmp/vm4a/dev --port 8000
# → http://192.168.64.7:8000

# Now curl it from your Mac:
curl -s "$(vm4a expose-port /tmp/vm4a/dev --port 8000)" | head
```

JSON and a custom scheme:

```bash
vm4a expose-port /tmp/vm4a/dev --port 443 --scheme https --output json
# → {"url":"https://192.168.64.7:443","host":"192.168.64.7","port":443,"scheme":"https"}
```

### Bridged VMs: `--host`

Bridged guests don't get an Apple DHCP lease, so pass the address yourself. With `--host`, `expose-port` skips the DHCP lookup entirely — it doesn't even need the bundle:

```bash
vm4a expose-port /tmp/vm4a/dev --port 8000 --host 10.0.0.42
```

## What you learned

- `run-code` collapses `cp`+`exec` into one call across `python`/`node`/`bash`/`sh`/`ruby`.
- `expose-port` turns a guest port into a host-reachable URL with no tunnel.
- `--host` makes `expose-port` work for bridged VMs (and without a bundle).

**Next:** [MCP integration](04-mcp) — hand these to an AI assistant as tools.
