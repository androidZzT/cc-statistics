"""cc-stats-web: start local web dashboard and optionally open browser."""

import argparse
import json
import threading
import webbrowser

from .server import start_server


def _build_startup_payload(host: str, port: int) -> dict:
    url = f"http://{host}:{port}/"
    return {
        "event": "cc_stats_web_started",
        "host": host,
        "port": port,
        "url": url,
    }


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="cc-stats-web",
        description="Start the local CC Statistics web dashboard.",
    )
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="Start the server without opening the default browser.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print a structured startup JSON line for desktop shells.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None):
    args = _parse_args(argv)
    server, port = start_server()
    payload = _build_startup_payload("127.0.0.1", port)
    url = payload["url"]
    if args.json:
        print(json.dumps(payload, ensure_ascii=False), flush=True)
    else:
        print(f"CC Stats Web Dashboard: {url}")
        print("Press Ctrl+C to stop.")

    if not args.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        server.shutdown()


if __name__ == "__main__":
    main()
