from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"svoi-mobile-tunnel-ok")

HTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
