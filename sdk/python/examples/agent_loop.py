"""End-to-end example: spawn a base VM, snapshot, fork per task, run code, reset on failure.

Prereq: `vm4a serve --port 7777` is running.

Run from the repo root:
    python sdk/python/examples/agent_loop.py
"""

from __future__ import annotations

import sys

from vm4a import Client


def main() -> int:
    c = Client()
    health = c.health()
    print(f"server: {health}")

    storage = "/tmp/vm4a"
    base_name = "py-dev"
    snapshot = f"{storage}/{base_name}/clean.vzstate"

    # 1. First-time bootstrap.
    if not any(vm.name == base_name for vm in c.list(storage=storage)):
        print("spawning base VM (this pulls the image and waits for SSH)...")
        vm = c.spawn(
            name=base_name,
            from_="ghcr.io/yourorg/python-dev-arm64:latest",
            storage=storage,
            save_on_stop=snapshot,
            wait_ssh=True,
            wait_timeout=180,
        )
        print(f"  base VM ready: {vm.id} at {vm.ip}")

        # Provision once.
        c.exec(vm.path, ["bash", "-lc", "apt-get update && apt-get install -y ripgrep"])
        c.stop(vm.path)  # save_on_stop saves the .vzstate at shutdown

    # 2. Per-task fork.
    task_id = "demo-001"
    task_path = f"{storage}/task-{task_id}"
    print(f"forking {base_name} → task-{task_id}")
    fork = c.fork(
        f"{storage}/{base_name}",
        task_path,
        from_snapshot=snapshot,
        auto_start=True,
        wait_ssh=True,
    )
    print(f"  task VM up at {fork.ip}")

    # 3. Push the agent step into the guest and run it.
    code = "import sys, platform; print('hello from', platform.node()); sys.exit(0)"
    c.exec(task_path, ["bash", "-lc", f"echo {code!r} > /tmp/step.py"])
    out = c.exec(task_path, ["python3", "/tmp/step.py"], timeout_seconds=30)
    print(f"  exit_code={out.exit_code} stdout={out.stdout!r}")

    # 4. If the task corrupted state, reset back to the snapshot.
    if out.exit_code != 0:
        print("step failed; resetting from snapshot")
        c.reset(task_path, from_=snapshot, wait_ip=True)

    # 5. Done.
    c.stop(task_path)
    return out.exit_code


if __name__ == "__main__":
    sys.exit(main())
