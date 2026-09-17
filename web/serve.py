import http.server, functools, sys
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        super().end_headers()
http.server.ThreadingHTTPServer(('127.0.0.1', 8911), functools.partial(H, directory=sys.argv[1])).serve_forever()
