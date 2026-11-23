#!/usr/bin/env python3
"""A local HTTPS proxy for the check «OpenAI is not reachable» (ui-check scenario ии-настройки, С21).

The platform ignores the list «do not use the proxy for these addresses» for HTTPS connections, so a dead proxy cuts
the portal of Bitrix24 as well as OpenAI. This proxy cuts only OpenAI: a CONNECT to a host ending with openai.com is
dropped without an answer (the platform reports «no connection»), every other CONNECT is tunnelled as it is.

Usage: block-proxy.py PORT [--pidfile FILE] [--log FILE]

The log has one line per connection: «blocked <host>» or «allowed <host>» (host names only: no keys, no content, the
traffic is encrypted and the proxy never reads it). ui-check.sh starts it, reads the log and stops it.
"""
import os
import socket
import socketserver
import sys
import threading

BLOCKED_SUFFIXES = ("openai.com",)
LOG_PATH = None
LOG_LOCK = threading.Lock()


def log(line):
    if not LOG_PATH:
        return
    with LOG_LOCK:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def pump(source, target):
    try:
        while True:
            chunk = source.recv(65536)
            if not chunk:
                break
            target.sendall(chunk)
    except OSError:
        pass
    finally:
        for s in (source, target):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(60)
        data = b""
        try:
            while b"\r\n\r\n" not in data:
                chunk = client.recv(4096)
                if not chunk or len(data) > 65536:
                    return
                data += chunk
        except OSError:
            return
        first_line = data.split(b"\r\n", 1)[0].decode("latin-1").split()
        if len(first_line) < 2 or first_line[0].upper() != "CONNECT":
            client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n")
            return
        host, _, port = first_line[1].rpartition(":")
        if host.lower().endswith(BLOCKED_SUFFIXES):
            log("blocked " + host)
            return
        try:
            upstream = socket.create_connection((host, int(port or 443)), timeout=15)
        except (OSError, ValueError):
            log("failed " + host)
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
            return
        log("allowed " + host)
        client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        client.settimeout(None)
        upstream.settimeout(None)
        thread = threading.Thread(target=pump, args=(upstream, client), daemon=True)
        thread.start()
        pump(client, upstream)
        thread.join(5)
        upstream.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main(argv):
    global LOG_PATH
    port = None
    pidfile = None
    while argv:
        arg = argv.pop(0)
        if arg == "--pidfile":
            pidfile = argv.pop(0)
        elif arg == "--log":
            LOG_PATH = argv.pop(0)
        else:
            port = int(arg)
    if port is None:
        print(__doc__, file=sys.stderr)
        return 2
    if LOG_PATH:
        open(LOG_PATH, "w", encoding="utf-8").close()
    server = Server(("127.0.0.1", port), Handler)
    if pidfile:
        with open(pidfile, "w", encoding="ascii") as f:
            f.write(str(os.getpid()))
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
