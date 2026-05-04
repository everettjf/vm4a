"""Thin urllib-based client for the vm4a HTTP API.

Uses only the Python standard library — no external dependencies.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence


class VM4AHTTPError(Exception):
    """Raised when the server returns a non-2xx response."""

    def __init__(self, status: int, message: str, body: str | None = None) -> None:
        super().__init__(f"vm4a HTTP {status}: {message}")
        self.status = status
        self.message = message
        self.body = body


@dataclass
class SpawnOutcome:
    id: str
    name: str
    path: str
    os: str
    pid: int | None
    ip: str | None
    ssh_ready: bool


@dataclass
class ExecResult:
    exit_code: int
    stdout: str
    stderr: str
    duration_ms: int
    timed_out: bool


@dataclass
class ForkOutcome:
    path: str
    name: str
    started: bool
    pid: int | None
    ip: str | None


@dataclass
class ResetOutcome:
    path: str
    restored: str
    pid: int | None
    ip: str | None


@dataclass
class StopOutcome:
    stopped: bool
    pid: int
    forced: bool | None
    reason: str | None


@dataclass
class VMSummary:
    id: str
    name: str
    path: str
    os: str
    status: str
    pid: int | None
    ip: str | None


@dataclass
class Lease:
    ip: str
    mac: str
    name: str | None


def _camel_to_snake(name: str) -> str:
    out: list[str] = []
    for ch in name:
        if ch.isupper():
            if out and out[-1] != "_":
                out.append("_")
            out.append(ch.lower())
        else:
            out.append(ch)
    return "".join(out)


def _from_dict(cls, d: Mapping[str, Any]):
    """Build a dataclass from a dict whose keys are either snake_case or camelCase."""
    fields = {f for f in cls.__dataclass_fields__}  # type: ignore[attr-defined]
    kwargs: dict[str, Any] = {}
    for k, v in d.items():
        snake = _camel_to_snake(k)
        if snake in fields:
            kwargs[snake] = v
    for f in fields:
        kwargs.setdefault(f, None)
    return cls(**kwargs)  # type: ignore[arg-type]


class Client:
    """Talks to a running `vm4a serve` instance.

    Parameters
    ----------
    base_url:
        Where the server is listening. Default `http://127.0.0.1:7777`.
    token:
        If the server was started with `VM4A_AUTH_TOKEN`, pass it here.
    timeout:
        Default per-request timeout in seconds. Long-running calls like
        `spawn(wait_ssh=True)` should override per-call.
    """

    def __init__(
        self,
        base_url: str = "http://127.0.0.1:7777",
        token: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.default_timeout = timeout

    # ------------------------------------------------------------------ low-level

    def _request(
        self,
        method: str,
        path: str,
        *,
        body: Mapping[str, Any] | None = None,
        query: Mapping[str, str] | None = None,
        timeout: float | None = None,
    ) -> Any:
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data: bytes | None = None
        headers: dict[str, str] = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.default_timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                payload = json.loads(raw)
                raise VM4AHTTPError(e.code, str(payload.get("error", payload)), raw.decode("utf-8", "replace"))
            except (ValueError, AttributeError):
                raise VM4AHTTPError(e.code, e.reason, raw.decode("utf-8", "replace"))
        if not raw:
            return None
        return json.loads(raw)

    # ------------------------------------------------------------------ tools

    def health(self) -> dict[str, Any]:
        return self._request("GET", "/v1/health")

    def spawn(
        self,
        name: str,
        *,
        os_: str = "linux",
        storage: str | None = None,
        from_: str | None = None,
        image: str | None = None,
        cpu: int | None = None,
        memory_gb: int | None = None,
        disk_gb: int | None = None,
        network: str | None = None,
        bridged_interface: str | None = None,
        rosetta: bool = False,
        restore: str | None = None,
        save_on_stop: str | None = None,
        wait_ip: bool = False,
        wait_ssh: bool = False,
        ssh_user: str | None = None,
        ssh_key: str | None = None,
        host: str | None = None,
        wait_timeout: int = 90,
        timeout: float | None = None,
    ) -> SpawnOutcome:
        body = _drop_none({
            "name": name, "os": os_, "storage": storage, "from": from_, "image": image,
            "cpu": cpu, "memory_gb": memory_gb, "disk_gb": disk_gb,
            "network": network,
            "bridged_interface": bridged_interface, "rosetta": rosetta,
            "restore": restore, "save_on_stop": save_on_stop,
            "wait_ip": wait_ip, "wait_ssh": wait_ssh,
            "ssh_user": ssh_user, "ssh_key": ssh_key,
            "host": host, "wait_timeout": wait_timeout,
        })
        # spawn can take a while; bias timeout up if not set
        effective = timeout if timeout is not None else max(self.default_timeout, wait_timeout + 5)
        return _from_dict(SpawnOutcome, self._request("POST", "/v1/spawn", body=body, timeout=effective))

    def exec(
        self,
        vm_path: str,
        command: Sequence[str],
        *,
        user: str | None = None,
        key: str | None = None,
        host: str | None = None,
        timeout_seconds: int = 60,
        timeout: float | None = None,
    ) -> ExecResult:
        body = _drop_none({
            "vm_path": vm_path,
            "command": list(command),
            "user": user, "key": key, "host": host,
            "timeout": timeout_seconds,
        })
        effective = timeout if timeout is not None else max(self.default_timeout, timeout_seconds + 5)
        return _from_dict(ExecResult, self._request("POST", "/v1/exec", body=body, timeout=effective))

    def cp(
        self,
        vm_path: str,
        source: str,
        destination: str,
        *,
        recursive: bool = False,
        user: str | None = None,
        key: str | None = None,
        host: str | None = None,
        timeout_seconds: int = 300,
        timeout: float | None = None,
    ) -> ExecResult:
        body = _drop_none({
            "vm_path": vm_path, "source": source, "destination": destination,
            "recursive": recursive,
            "user": user, "key": key, "host": host,
            "timeout": timeout_seconds,
        })
        effective = timeout if timeout is not None else max(self.default_timeout, timeout_seconds + 5)
        return _from_dict(ExecResult, self._request("POST", "/v1/cp", body=body, timeout=effective))

    def fork(
        self,
        source_path: str,
        destination_path: str,
        *,
        from_snapshot: str | None = None,
        auto_start: bool = False,
        wait_ip: bool = False,
        wait_ssh: bool = False,
        ssh_user: str | None = None,
        ssh_key: str | None = None,
        wait_timeout: int = 90,
        timeout: float | None = None,
    ) -> ForkOutcome:
        body = _drop_none({
            "source_path": source_path, "destination_path": destination_path,
            "from_snapshot": from_snapshot, "auto_start": auto_start,
            "wait_ip": wait_ip, "wait_ssh": wait_ssh,
            "ssh_user": ssh_user, "ssh_key": ssh_key,
            "wait_timeout": wait_timeout,
        })
        effective = timeout if timeout is not None else max(self.default_timeout, wait_timeout + 5)
        return _from_dict(ForkOutcome, self._request("POST", "/v1/fork", body=body, timeout=effective))

    def reset(
        self,
        vm_path: str,
        from_: str,
        *,
        wait_ip: bool = False,
        stop_timeout: int = 20,
        wait_timeout: int = 60,
        timeout: float | None = None,
    ) -> ResetOutcome:
        body = _drop_none({
            "vm_path": vm_path, "from": from_,
            "wait_ip": wait_ip, "stop_timeout": stop_timeout, "wait_timeout": wait_timeout,
        })
        effective = timeout if timeout is not None else max(self.default_timeout, wait_timeout + 5)
        return _from_dict(ResetOutcome, self._request("POST", "/v1/reset", body=body, timeout=effective))

    def list(self, *, storage: str | None = None) -> list[VMSummary]:
        query = {"storage": storage} if storage else None
        rows = self._request("GET", "/v1/vms", query=query)
        return [_from_dict(VMSummary, r) for r in rows or []]

    def ip(self, vm_path: str) -> list[Lease]:
        rows = self._request("GET", "/v1/vms/ip", query={"path": vm_path})
        return [_from_dict(Lease, r) for r in rows or []]

    def stop(self, vm_path: str, *, timeout_seconds: int = 20) -> StopOutcome:
        body = {"vm_path": vm_path, "timeout": timeout_seconds}
        return _from_dict(StopOutcome, self._request("POST", "/v1/vms/stop", body=body))


def _drop_none(d: Mapping[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in d.items() if v is not None and v != ""}
