"""cc-stats-web: start local web dashboard and open browser"""

import threading
import webbrowser

from .server import start_server


def main():
    server, port = start_server()
    url = f"http://127.0.0.1:{port}/"
    print(f"CC Stats Web Dashboard: {url}")
    print("Press Ctrl+C to stop.")

    # Open browser after short delay
    threading.Timer(0.5, lambda: webbrowser.open(url)).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        server.shutdown()


if __name__ == "__main__":
    main()
