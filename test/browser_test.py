#!/usr/bin/env python3
"""Drive the wasm build in headless Chromium and assert it reaches the tip.

    python3 test/browser_test.py [expected_height]

Serves web/ with COOP and COEP (SharedArrayBuffer needs cross-origin
isolation, and the script verification threads need SharedArrayBuffer),
loads the page, waits for the run to finish, and checks the reported tip.
"""
import http.server
import functools
import os
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(ROOT, "web")
PORT = int(os.environ.get("PORT", "8911"))
EXPECTED_HEIGHT = int(sys.argv[1]) if len(sys.argv) > 1 else 330


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

    def log_message(self, *args):
        pass


def serve():
    httpd = http.server.ThreadingHTTPServer(
        ("127.0.0.1", PORT), functools.partial(Handler, directory=WEB)
    )
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def main():
    from playwright.sync_api import sync_playwright

    if not os.path.exists(os.path.join(WEB, "bitcoin-chainstate.wasm")):
        sys.exit("web/bitcoin-chainstate.wasm missing, run ./build.sh first")

    httpd = serve()
    time.sleep(0.3)
    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--no-sandbox"])
        page = browser.new_page()
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"http://127.0.0.1:{PORT}/index.html")
        assert page.evaluate("window.crossOriginIsolated"), "page is not cross-origin isolated"
        t0 = time.time()
        page.wait_for_function("window.__done === true", timeout=300000)
        elapsed = time.time() - t0
        result = page.evaluate("({log: window.__log, err: window.__err, exit: window.__exit})")
        browser.close()
    httpd.shutdown()

    log = "\n".join(result["log"])
    tip = f"height={EXPECTED_HEIGHT}"
    ok = result["exit"] == 0 and tip in log and not errors
    print(f"elapsed={elapsed:.2f}s exit={result['exit']} tip_reached={tip in log}")
    if not ok:
        print("--- stdout tail ---")
        print("\n".join(result["log"][-15:]))
        print("--- stderr tail ---")
        print("\n".join(result["err"][-15:]))
        print("--- page errors ---")
        print("\n".join(errors))
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
