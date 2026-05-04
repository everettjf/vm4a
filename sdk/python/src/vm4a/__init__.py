"""vm4a — Python client for the local vm4a HTTP API.

Quick start:

    from vm4a import Client

    c = Client()                          # http://127.0.0.1:7777, no auth
    vm = c.spawn(name="dev", from_="ghcr.io/yourorg/python-dev:latest",
                 wait_ssh=True)
    out = c.exec(vm.path, ["python3", "-c", "print(1+1)"])
    print(out.exit_code, out.stdout)

The CLI must be running: `vm4a serve --port 7777`. Set VM4A_AUTH_TOKEN
on the server side and pass `token=` to Client to require auth.
"""

from .client import (
    Client,
    SpawnOutcome,
    ExecResult,
    ForkOutcome,
    ResetOutcome,
    StopOutcome,
    VMSummary,
    Lease,
    VM4AHTTPError,
)

__all__ = [
    "Client",
    "SpawnOutcome",
    "ExecResult",
    "ForkOutcome",
    "ResetOutcome",
    "StopOutcome",
    "VMSummary",
    "Lease",
    "VM4AHTTPError",
]
__version__ = "2.0.0"
