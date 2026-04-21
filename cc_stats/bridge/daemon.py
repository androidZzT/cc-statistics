from __future__ import annotations

import argparse
import signal
import subprocess
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from .api_server import BridgeHTTPServer
from .collector import ClaudeStreamJsonCollector, StreamCollectorConfig
from .models import Event, EventType
from .state_store import BridgeStateStore


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="cc-stats-bridge",
        description="Claude Code -> Dynamic Island bridge daemon (MVP).",
    )
    parser.add_argument("--host", default="127.0.0.1", help="HTTP bind host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8765, help="HTTP bind port (default: 8765)")
    parser.add_argument("--task-id", default=f"task_{uuid4().hex}", help="Task id for this run")
    parser.add_argument("--session-id", default="", help="Claude session id")
    parser.add_argument("--task-title", default="Claude Code Task", help="Task title shown on Island")
    parser.add_argument("--repo", default=str(Path.cwd()), help="Repo path or name")
    parser.add_argument(
        "--stdin-stream",
        action="store_true",
        help="Read Claude stream-json events from stdin",
    )
    parser.add_argument(
        "--stream-command",
        nargs=argparse.REMAINDER,
        help="Command to run and consume as stream-json (use after '--')",
    )
    args = parser.parse_args(argv)

    if args.stdin_stream and args.stream_command:
        print("Cannot use --stdin-stream and --stream-command together.", file=sys.stderr)
        sys.exit(2)

    stream_command = _normalize_stream_command(args.stream_command)
    store = BridgeStateStore()
    session_id = args.session_id or f"session_{uuid4().hex}"
    collector = ClaudeStreamJsonCollector(
        store=store,
        config=StreamCollectorConfig(
            task_id=args.task_id,
            session_id=session_id,
            title=args.task_title,
            repo=args.repo,
        ),
    )

    server = BridgeHTTPServer((args.host, args.port), store=store)
    _install_signal_handlers(server)

    workers: list[threading.Thread] = []
    if args.stdin_stream:
        workers.append(_spawn_stdin_worker(collector))
    elif stream_command:
        workers.extend(_spawn_command_workers(collector, stream_command))
    else:
        _emit_synthetic_start(store, args.task_id, session_id, args.task_title, args.repo)

    print(f"[cc-stats-bridge] listening on http://{args.host}:{args.port}", file=sys.stderr)
    if args.stdin_stream:
        print("[cc-stats-bridge] source: stdin stream-json", file=sys.stderr)
    elif stream_command:
        print(f"[cc-stats-bridge] source command: {' '.join(stream_command)}", file=sys.stderr)
    else:
        print("[cc-stats-bridge] source: none (synthetic start event only)", file=sys.stderr)

    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        for worker in workers:
            worker.join(timeout=2.0)


def _normalize_stream_command(raw: list[str] | None) -> list[str]:
    if not raw:
        return []
    cmd = list(raw)
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    return cmd


def _spawn_stdin_worker(collector: ClaudeStreamJsonCollector) -> threading.Thread:
    def _worker() -> None:
        for line in sys.stdin:
            collector.feed_line(line)

    th = threading.Thread(target=_worker, name="bridge-stdin-worker", daemon=True)
    th.start()
    return th


def _spawn_command_workers(collector: ClaudeStreamJsonCollector, cmd: list[str]) -> list[threading.Thread]:
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    def _stdout_worker() -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            collector.feed_line(line)
        code = proc.wait()
        if code != 0:
            collector.feed_object(
                {
                    "type": "error",
                    "error_code": f"exit_{code}",
                    "error_message": f"stream command exited with code {code}",
                    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                }
            )
        else:
            collector.feed_object(
                {
                    "type": "completed",
                    "summary": "stream command finished",
                    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                }
            )

    def _stderr_worker() -> None:
        assert proc.stderr is not None
        for line in proc.stderr:
            sys.stderr.write(f"[stream] {line}")
            sys.stderr.flush()

    out_th = threading.Thread(target=_stdout_worker, name="bridge-cmd-stdout", daemon=True)
    err_th = threading.Thread(target=_stderr_worker, name="bridge-cmd-stderr", daemon=True)
    out_th.start()
    err_th.start()
    return [out_th, err_th]


def _emit_synthetic_start(
    store: BridgeStateStore,
    task_id: str,
    session_id: str,
    title: str,
    repo: str,
) -> None:
    event = Event(
        version=1,
        event_id=f"evt_{uuid4().hex}",
        type=EventType.TASK_STARTED,
        task_id=task_id,
        session_id=session_id,
        timestamp=datetime.now(timezone.utc),
        payload={"title": title, "repo": repo, "model": ""},
    )
    store.apply_event(event)


def _install_signal_handlers(server: BridgeHTTPServer) -> None:
    def _shutdown_handler(signum: int, _frame: object) -> None:
        print(f"\n[cc-stats-bridge] received signal {signum}, shutting down...", file=sys.stderr)
        threading.Thread(target=server.shutdown, daemon=True).start()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, _shutdown_handler)
        except ValueError:
            # Signal handlers can only be installed in main thread.
            continue


if __name__ == "__main__":
    main()
