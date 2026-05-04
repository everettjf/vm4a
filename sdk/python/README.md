# vm4a — Python client

Thin Python client for the local **vm4a** HTTP API. Zero runtime dependencies; uses only the standard library.

```bash
# Start the server (one-time, in another terminal)
vm4a serve --port 7777

# Install the SDK
pip install vm4a
```

```python
from vm4a import Client

c = Client()  # http://127.0.0.1:7777, no auth

# Pull-and-start an OCI bundle, wait until SSH responds
vm = c.spawn(
    name="dev",
    from_="ghcr.io/yourorg/python-dev:latest",
    storage="/tmp/vm4a",
    wait_ssh=True,
)
print("VM ready:", vm.id, vm.ip)

# Run code in the guest
out = c.exec(vm.path, ["python3", "-c", "print(1+1)"], timeout_seconds=30)
print("exit", out.exit_code, "stdout:", out.stdout)

# Push code in, run a step
c.cp(vm.path, "./step.py", ":/work/step.py")
result = c.exec(vm.path, ["python3", "/work/step.py"])

# Per-task fork pattern
c.fork("/tmp/vm4a/dev", "/tmp/vm4a/task-42",
       from_snapshot="/tmp/vm4a/dev/clean.vzstate",
       auto_start=True, wait_ssh=True)
```

### Auth

If the server was started with `VM4A_AUTH_TOKEN=...`, pass the same token to the client:

```python
Client(token="...")
```

### API surface

| Method | Maps to |
|---|---|
| `client.spawn(...)` | `POST /v1/spawn` |
| `client.exec(vm_path, [...])` | `POST /v1/exec` |
| `client.cp(vm_path, src, dst)` | `POST /v1/cp` |
| `client.fork(src, dst, ...)` | `POST /v1/fork` |
| `client.reset(vm_path, from_=...)` | `POST /v1/reset` |
| `client.list()` | `GET /v1/vms` |
| `client.ip(vm_path)` | `GET /v1/vms/ip` |
| `client.stop(vm_path)` | `POST /v1/vms/stop` |
| `client.health()` | `GET /v1/health` |

All methods return dataclass instances (`SpawnOutcome`, `ExecResult`, ...) with snake_case fields. Non-2xx responses raise `VM4AHTTPError`.

### Examples

See [examples/agent_loop.py](examples/agent_loop.py) for an end-to-end agent loop using `spawn` + `fork` + `exec` + `reset`.
