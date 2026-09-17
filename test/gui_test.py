#!/usr/bin/env python3
"""Load a deployed bitcoin-qt build in headless Chromium and assert it starts.

    python3 test/gui_test.py <deployed-dir>

Serves the directory with the same isolation headers nginx sends, drives a
desktop and a phone viewport, and fails if either behaves wrongly.

This test exists because its absence let a page ship that threw a ReferenceError
before its first fetch and sat on an empty progress bar. Nothing else in the
repository ever loads web-gui/ in a browser.
"""
import functools
import http.server
import os
import sys
import threading
import time

PORT = int(os.environ.get("PORT", "8914"))
WAIT = int(os.environ.get("WAIT", "120"))
PHONE_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        super().end_headers()

    def log_message(self, *args):
        pass


def main():
    from playwright.sync_api import sync_playwright

    web = sys.argv[1] if len(sys.argv) > 1 else None
    if not web or not os.path.isfile(os.path.join(web, "manifest.json")):
        sys.exit("usage: gui_test.py <deployed-dir>   (a directory deploy.sh wrote)")

    httpd = http.server.ThreadingHTTPServer(
        ("127.0.0.1", PORT), functools.partial(Handler, directory=web))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{PORT}/index.html"
    failures = []

    with sync_playwright() as p:
        browser = p.chromium.launch(
            args=["--no-sandbox", "--use-gl=swiftshader", "--enable-unsafe-swiftshader"])

        # A phone must be turned away without fetching the 74 MB.
        phone = browser.new_context(viewport={"width": 390, "height": 844}, is_mobile=True,
                                    has_touch=True, user_agent=PHONE_UA).new_page()
        big = []
        phone.on("request", lambda r: big.append(r.url)
                 if r.url.endswith((".wasm", ".data")) else None)
        phone.goto(url)
        time.sleep(5)
        if not phone.is_visible("#nomobile"):
            failures.append("phone: the desktop-only notice was not shown")
        if big:
            failures.append(f"phone: downloaded {len(big)} large file(s) anyway")

        # A desktop must reach a running node with no page error.
        desktop = browser.new_context(viewport={"width": 1200, "height": 800}).new_page()
        errors = []
        desktop.on("pageerror", lambda e: errors.append(str(e)[:200]))
        desktop.goto(url)
        if not desktop.evaluate("window.crossOriginIsolated"):
            failures.append("desktop: page is not cross-origin isolated")
        try:
            desktop.wait_for_function(
                "document.getElementById('boot').style.display === 'none'", timeout=WAIT * 1000)
        except Exception:
            failures.append(f"desktop: the node did not start within {WAIT}s")
        if errors:
            failures.append("desktop: page errors: " + " | ".join(errors[:3]))

        browser.close()
    httpd.shutdown()

    if failures:
        for f in failures:
            print("FAIL " + f)
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
