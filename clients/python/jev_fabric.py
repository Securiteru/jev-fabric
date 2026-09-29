"""A thin client for `jev-fabric -- serve`, the JSONL session protocol.

One file, standard library only, Python 3.9+. Copy it next to your code, or
import it from ``~/.local/share/jev-fabric/current/clients/python``.

The client starts one ``serve`` child, writes one request line per call and
returns the response that carries the same id. Calls from several threads may
overlap: serve answers them concurrently, in any order. Budgets, deadlines,
credentials and Jev validation all live in the executable; this module only
frames JSON.

    from jev_fabric import Fabric

    with Fabric(max_evaluations=10) as fabric:
        job = fabric.start(["/bin/sh", "-c", "npm run dev"])
        fabric.watch(job, "ready", timeout_ms=30000)

        repl = fabric.spawn(["python3", "-i"])["id"]    # a session child
        fabric.write(repl, "print(6 * 7)\n")
        out = fabric.read(repl, "stdout", wait_ms=5000)
    # leaving the block ends the session and stops repl
"""

from __future__ import annotations

import itertools
import json
import os
import subprocess
import threading
from typing import Any, Dict, List, Mapping, Optional, Sequence

__all__ = ["Fabric", "FabricError", "PROTOCOL"]

# The protocol major this client speaks; features are only added within it.
PROTOCOL = 2

Json = Dict[str, Any]


class FabricError(Exception):
    """A request the session refused or could not complete.

    ``code`` follows the CLI's exit codes: 2 for a malformed request, 22 for a
    rejected value, 124 for an expired deadline, 1 otherwise.
    """

    def __init__(self, code: int, message: str, op: Optional[str] = None) -> None:
        super().__init__(f"{op}: {message}" if op else message)
        self.code = code
        self.message = message
        self.op = op


class _Slot:
    """One request waiting for the response with its id."""

    __slots__ = ("done", "response")

    def __init__(self) -> None:
        self.done = threading.Event()
        self.response: Optional[Json] = None


class Fabric:
    """One ``jev-fabric -- serve`` session.

    ``timeout_ms`` bounds the whole session (default: the CLI work default, one
    hour; at most 86400000). ``max_evaluations`` and ``max_tokens`` bound Jev
    calls for the whole session (defaults: 1 evaluation, 100000 reported
    tokens, as for ``jev``). ``binary`` defaults to ``$JEV_FABRIC_BIN`` or
    ``jev-fabric`` on PATH.

    The object is safe to share between threads, and their calls overlap:
    a background thread matches each response to its request by id. Writes,
    closes and stops of one session child apply in the order they were sent;
    ``jev`` calls run one at a time. Closing the session stops its children.
    """

    def __init__(
        self,
        *,
        binary: Optional[str] = None,
        timeout_ms: Optional[int] = None,
        max_evaluations: Optional[int] = None,
        max_tokens: Optional[int] = None,
        env: Optional[Mapping[str, str]] = None,
        cwd: Optional[str] = None,
    ) -> None:
        executable = binary or os.environ.get("JEV_FABRIC_BIN") or "jev-fabric"
        argv = [executable, "--", "serve"]
        if timeout_ms is not None:
            argv += ["--timeout-ms", str(timeout_ms)]
        if max_tokens is not None and max_evaluations is None:
            max_evaluations = 1
        if max_evaluations is not None:
            argv.append(str(max_evaluations))
        if max_tokens is not None:
            argv.append(str(max_tokens))
        self._process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=None if env is None else dict(env),
            cwd=cwd,
        )
        self._ids = itertools.count(1)
        # The reader thread takes only _lock; a writer blocked on a full pipe
        # holds _write_lock and never stops responses from being delivered.
        self._lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._pending: Dict[int, _Slot] = {}
        self._ended_error: Optional[FabricError] = None
        banner = self._read_line()
        ready = banner.get("ready")
        if not isinstance(ready, dict) or ready.get("protocol") != PROTOCOL:
            self.close()
            raise FabricError(1, f"unsupported serve protocol: {banner!r}")
        self.ready: Json = ready
        self._reader = threading.Thread(target=self._pump, name="jev-fabric-serve", daemon=True)
        self._reader.start()

    # -- processes -----------------------------------------------------------

    def exec(
        self,
        argv: Sequence[str],
        *,
        stdin: Optional[str] = None,
        timeout_ms: Optional[int] = None,
        cwd: Optional[str] = None,
    ) -> Json:
        """Run literal argv to completion and return its bounded receipt.

        A nonzero exit is a receipt with ``state: "failed"``, not an error.
        ``cwd`` is an absolute directory the command starts in.
        """
        return self._call("exec", argv=list(argv), stdin=stdin, timeoutMs=timeout_ms, cwd=cwd)

    def start(
        self,
        argv: Sequence[str],
        *,
        timeout_ms: Optional[int] = None,
        label: Optional[str] = None,
        cwd: Optional[str] = None,
        input: Optional[str] = None,
    ) -> str:
        """Start a detached job that outlives this session; returns its id.

        ``timeout_ms`` is the job's own lifetime, up to 86400000 (24 hours).
        ``label`` is 1..120 printable characters on one line. With
        ``input="pipe"`` its stdin stays open for :meth:`write`.
        """
        return self._call(
            "start", argv=list(argv), timeoutMs=timeout_ms, label=label, cwd=cwd, input=input
        )["id"]

    def spawn(
        self,
        argv: Sequence[str],
        *,
        stdin: Optional[str] = None,
        timeout_ms: Optional[int] = None,
        label: Optional[str] = None,
        cwd: Optional[str] = None,
    ) -> Json:
        """Start a session child and return its running state (``id`` is ``s-…``).

        It lives until it exits, its own ``timeout_ms`` (up to 24 hours) passes,
        it is stopped, or this session ends. With ``stdin="pipe"`` (the default)
        its stdin stays open for :meth:`write`; ``"null"`` starts it closed.
        """
        return self._call(
            "spawn", argv=list(argv), stdin=stdin, timeoutMs=timeout_ms, label=label, cwd=cwd
        )

    def write(self, job: str, text: str) -> Json:
        """Append up to 65536 characters to an interactive child's stdin, in order."""
        return self._call("write", job=job, text=text)

    def close_input(self, job: str) -> Json:
        """End an interactive child's stdin. Idempotent."""
        return self._call("closeInput", job=job)

    def read(
        self,
        job: str,
        stream: str,
        *,
        offset: Optional[int] = None,
        max: Optional[int] = None,
        wait_ms: Optional[int] = None,
        encoding: Optional[str] = None,
    ) -> Json:
        """Up to ``max`` (default and limit 65536) bytes of ``stream`` from ``offset``.

        Returns a read record: ``offset``, ``bytes``, ``omittedBytes`` (loss
        before this read), ``text`` (or ``data`` in base64 with
        ``encoding="base64"``), ``next``, ``eof`` and ``state``. With ``wait_ms``
        (1..300000), a long poll that answers as soon as bytes past ``offset``
        exist, the stream ends, or ``wait_ms`` passes.
        """
        return self._call(
            "read", job=job, stream=stream, offset=offset, max=max, waitMs=wait_ms, encoding=encoding
        )

    def status(self, job: str) -> Json:
        return self._call("status", job=job)

    def events(self, job: str, *, after: int = 0, wait_ms: Optional[int] = None) -> List[Json]:
        """Retained events with a sequence above ``after`` (a bounded snapshot).

        With ``wait_ms`` (1..300000), a long poll: it returns once such an event
        exists or the job is terminal, or the (possibly empty) list once
        ``wait_ms`` passes.
        """
        return self._call("events", job=job, after=after, waitMs=wait_ms)

    def list(self, *, scope: Optional[str] = None) -> Json:
        """Job directories under the storage root: ``{"jobs": [...], "truncated": bool}``.

        With ``scope="session"``, this session's children instead.
        """
        return self._call("list", scope=scope)

    def capabilities(self) -> Json:
        """The binary's version, protocol, store format, platform and features."""
        return self._call("capabilities")

    def wait(self, job: str, *, timeout_ms: Optional[int] = None) -> Json:
        """The final receipt, or the running state once ``timeout_ms`` passes."""
        return self._call("wait", job=job, timeoutMs=timeout_ms)

    def stop(self, job: str) -> Json:
        return self._call("stop", job=job)

    def watch(self, job: str, literal: str, *, timeout_ms: Optional[int] = None) -> List[Json]:
        """Live output lines containing ``literal``, as monitor records."""
        return self._call("watch", job=job, literal=literal, timeoutMs=timeout_ms)

    # -- Jev -----------------------------------------------------------------

    def validate(self, request: Json) -> Json:
        """Strictly validate a Jev request offline, without credentials."""
        return self._call("validate", request=request)

    def jev(
        self,
        request: Json,
        *,
        timeout_ms: Optional[int] = None,
        provider: Optional[str] = None,
        credential: Optional[str] = None,
    ) -> Json:
        """One explicit, billed evaluation against the session budget.

        ``provider`` and ``credential`` apply to this request only; the
        credential travels over the private pipe and is never cached or echoed.
        """
        return self._call(
            "jev", request=request, timeoutMs=timeout_ms, provider=provider, credential=credential
        )

    # -- session -------------------------------------------------------------

    def close(self, timeout: float = 10.0) -> int:
        """End the session by closing its input; returns the exit code.

        serve answers every request in flight and stops the session children
        before it exits.
        """
        process = self._process
        if process.stdin and not process.stdin.closed:
            try:
                with self._write_lock:
                    process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            return process.wait()

    def __enter__(self) -> "Fabric":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- framing -------------------------------------------------------------

    def _call(self, op: str, **fields: Any) -> Any:
        slot = _Slot()
        with self._lock:
            if self._ended_error is not None:
                raise self._error_for(op)
            request_id = next(self._ids)
            self._pending[request_id] = slot
        request = {"id": request_id, "op": op}
        request.update((k, v) for k, v in fields.items() if v is not None)
        line = json.dumps(request, ensure_ascii=False, separators=(",", ":"))
        try:
            with self._write_lock:
                assert self._process.stdin is not None
                self._process.stdin.write(line.encode("utf-8") + b"\n")
                self._process.stdin.flush()
        except (BrokenPipeError, ValueError):
            with self._lock:
                self._pending.pop(request_id, None)
            self._reader.join()
            raise self._error_for(op) from None
        slot.done.wait()
        response = slot.response
        if response is None:
            raise self._error_for(op)
        if response.get("ok"):
            return response["result"]
        error = response.get("error") or {}
        raise FabricError(int(error.get("code", 1)), str(error.get("message", "request failed")), op)

    def _pump(self) -> None:
        """Delivers each response line to the request with the same id."""
        assert self._process.stdout is not None
        try:
            for line in self._process.stdout:
                response = json.loads(line)
                with self._lock:
                    slot = self._pending.pop(response.get("id"), None) if isinstance(response.get("id"), int) else None
                if slot is not None:
                    slot.response = response
                    slot.done.set()
        finally:
            error = self._ended(None)
            with self._lock:
                self._ended_error = error
                waiting = list(self._pending.values())
                self._pending.clear()
            for slot in waiting:
                slot.done.set()

    def _error_for(self, op: Optional[str]) -> FabricError:
        ended = self._ended_error or self._ended(None)
        return FabricError(ended.code, ended.message, op)

    def _read_line(self, op: Optional[str] = None) -> Json:
        assert self._process.stdout is not None
        line = self._process.stdout.readline()
        if not line:
            raise self._ended(op)
        return json.loads(line)

    def _ended(self, op: Optional[str]) -> FabricError:
        code = self._process.wait()
        stderr = self._process.stderr.read().decode("utf-8", "replace").strip() if self._process.stderr else ""
        return FabricError(code or 1, stderr or f"serve exited with code {code}", op)
