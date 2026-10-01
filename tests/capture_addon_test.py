#!/usr/bin/env python3
"""Behavioural test of the GENERATED mitmproxy addon (nixenv_capture.py),
without mitmproxy: a stub package stands in for the few names it imports.

Usage: capture_addon_test.py <addon.py> <workdir>
Exits non-zero with a message on the first failure.
"""
import asyncio
import importlib.util
import os
import sys
sys.dont_write_bytecode = True
import types
from types import SimpleNamespace as NS

addon_path, work = sys.argv[1], sys.argv[2]


# --- stub mitmproxy ---------------------------------------------------------
class Headers(dict):
    """Case-insensitive enough for the addon: keys stored lower-case."""
    def __init__(self, **kw):
        super().__init__({k.lower().replace("_", "-"): v for k, v in kw.items()})

    def get(self, k, d=None):
        return super().get(k.lower(), d)

    def pop(self, k, *d):
        return super().pop(k.lower(), *d)

    def __setitem__(self, k, v):
        super().__setitem__(k.lower(), v)

    def __getitem__(self, k):
        return super().__getitem__(k.lower())


class Request:
    def __init__(self, host, port, headers, method="GET", url=None):
        self._host, self.port, self.headers, self.method = host, port, headers, method
        self.pretty_url = url or f"http://{host}:{port}/"

    @property
    def host(self):
        return self._host

    @host.setter
    def host(self, v):   # like mitmproxy: setting .host rewrites the Host header
        self._host = v
        if "host" in self.headers:
            self.headers["host"] = v


class Response:
    def __init__(self, status=200, body=b"", headers=None):
        self.status_code, self.raw_content = status, body
        self.headers = headers or Headers()
        self.stream = False

    @staticmethod
    def make(status, body=b""):
        return Response(status, body)


class FlowWriter:
    def __init__(self, fh):
        self.fh = fh

    def add(self, flow):
        self.fh.write(b"FLOW\n")


mp = types.ModuleType("mitmproxy")
mp.http = types.ModuleType("mitmproxy.http")
mp.http.Response = Response
mp.io = types.ModuleType("mitmproxy.io")
mp.io.FlowWriter = FlowWriter
sys.modules.update({"mitmproxy": mp, "mitmproxy.http": mp.http, "mitmproxy.io": mp.io})

# --- load the addon against a test config -----------------------------------
conf = os.path.join(work, "capture.conf")
with open(conf, "w") as f:
    f.write("# comment\n"
            "egress alpha 8101\n"
            "ingress alpha 8201 nxt-alpha\n"
            "egress beta 8102\n"
            "link 172.26.0.0/16\n")
os.environ["NIXENV_CAPTURE_CONF"] = conf
os.environ["NIXENV_CAPTURE_DIR"] = os.path.join(work, "captures")
spec = importlib.util.spec_from_file_location("nixenv_capture", addon_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
cap = mod.addons[0]


def check(cond, msg):
    if not cond:
        print("FAIL:", msg)
        sys.exit(1)


def client(port, peer="127.0.0.1"):
    return NS(sockname=("0.0.0.0", port), peername=(peer, 40000), error=None, sni="x.example")


# --- listener → project -----------------------------------------------------
check(cap.who(client(8101)) == ("egress", "alpha", None), "egress listener maps to its project")
check(cap.who(client(8201)) == ("ingress", "alpha", "nxt-alpha"), "ingress listener maps to its container")
check(cap.who(client(9999)) is None, "unknown port maps to nothing")

# --- client_connected: who may use which listener ---------------------------
c = client(9999); cap.client_connected(c)
check(c.error, "connection on an unknown listener is killed")
c = client(8101); cap.client_connected(c)
check(not c.error, "squid (loopback) may use an egress listener")
c = client(8201, "172.26.0.3"); cap.client_connected(c)
check(not c.error, "Caddy (link subnet) may use the ingress listener")
c = client(8201, "172.30.9.5"); cap.client_connected(c)
check(c.error, "a project (internal net) may NOT use the ingress listener")


# --- server_connect: address re-check on egress ------------------------------
def connect(port, host, answers, sport=443):
    loop = asyncio.new_event_loop()

    async def fake_getaddrinfo(h, p, **kw):
        if answers is None:
            raise OSError("no such host")
        return [(None, None, None, "", (ip, p)) for ip in answers]
    loop.getaddrinfo = fake_getaddrinfo
    data = NS(client=client(port), server=NS(address=(host, sport), error=None))
    loop.run_until_complete(cap.server_connect(data))
    loop.close()
    return data.server


srv = connect(8101, "api.example.com", ["2606:4700::1", "93.184.216.34"])
check(not srv.error and srv.address == ("93.184.216.34", 443),
      f"public answer: pinned to the checked IPv4 address ({srv.address}, {srv.error})")
srv = connect(8101, "rebind.example.com", ["10.1.2.3"])
check(srv.error, "a name resolving to a private address is refused")
srv = connect(8101, "mixed.example.com", ["93.184.216.34", "127.0.0.1"])
check(srv.error, "ANY non-public answer refuses the connection")
srv = connect(8101, "meta.example.com", ["169.254.169.254"])
check(srv.error, "link-local (cloud metadata) refused")
srv = connect(8101, "v6.example.com", ["::ffff:10.0.0.1"])
check(srv.error, "IPv4-mapped private address refused")
srv = connect(8101, "nx.example.com", None)
check(srv.error, "resolution failure is an error, not a direct connection")
srv = connect(8201, "nxt-alpha", ["172.30.9.5"], 3000)
check(not srv.error, "ingress may reach its own (private) container")
srv = connect(8201, "nxt-beta", ["172.30.9.6"], 3000)
check(srv.error, "ingress may NOT reach another project's container")


# --- requestheaders: tagging + ingress upstream ------------------------------
def flow(port, req, peer="127.0.0.1", replay=None):
    return NS(client_conn=client(port, peer), request=req, response=None, error=None,
              comment="", is_replay=replay)


f = flow(8102, Request("example.org", 443, Headers(host="example.org")))
cap.requestheaders(f)
check(f.comment == "beta egress", f"flows are tagged with the project ({f.comment!r})")

req = Request("alpha-3000.nixenv.localhost", 443,
              Headers(host="alpha-3000.nixenv.localhost", x_nixenv_upstream="nxt-alpha:3000"))
f = flow(8201, req, "172.26.0.3"); cap.requestheaders(f)
check(f.response is None, "valid upstream accepted")
check((req.host, req.port) == ("nxt-alpha", 3000), "request goes to the upstream Caddy chose")
check(req.headers.get("host") == "alpha-3000.nixenv.localhost", "the app still sees the PUBLIC Host")
check(req.headers.get("x-nixenv-upstream") is None, "the upstream header is stripped")

for bad in ["nxt-beta:3000", "nxt-alpha:x", "", "nxt-alpha"]:
    hdr = Headers(host="alpha-3000.nixenv.localhost")
    if bad:
        hdr["x-nixenv-upstream"] = bad
    f = flow(8201, Request("alpha-3000.nixenv.localhost", 443, hdr), "172.26.0.3")
    cap.requestheaders(f)
    check(f.response is not None and f.response.status_code == 502, f"bad upstream {bad!r} → 502")

# Replay (mitmweb/tui) re-sends the RECORDED request: already aimed at the
# container, upstream header gone. It must work — and stay on this project.
req = Request("nxt-alpha", 3000, Headers(host="alpha-3000.nixenv.localhost"))
f = flow(8201, req, "172.26.0.3", replay="request"); cap.requestheaders(f)
check(f.response is None, "replay of a recorded ingress request is accepted")
check((req.host, req.port) == ("nxt-alpha", 3000), "replay keeps the recorded upstream")
check(req.headers.get("host") == "alpha-3000.nixenv.localhost", "replay keeps the PUBLIC Host")
check(f.comment == "alpha ingress", "replay is tagged too")
f = flow(8201, Request("nxt-beta", 3000, Headers(host="nxt-beta")), "172.26.0.3", replay="request")
cap.requestheaders(f)
check(f.response is not None and f.response.status_code == 502, "an edited replay to another container → 502")

# --- streaming + saving ------------------------------------------------------
f = flow(8101, Request("example.com", 443, Headers()))
f.response = Response(200, None, Headers(content_type="text/event-stream; charset=utf-8"))
cap.responseheaders(f)
check(f.response.stream is True, "event streams are never buffered")

f = flow(8101, Request("example.com", 443, Headers(), url="https://example.com/x"))
f.response = Response(201, b"hello")
cap.response(f)
f = flow(8101, Request("example.com", 443, Headers(), url="https://example.com/y"))
f.error = NS(msg="boom")
cap.error(f)
cdir = os.environ["NIXENV_CAPTURE_DIR"]
with open(os.path.join(cdir, "alpha.log")) as fh:
    log = fh.read()
check("GET https://example.com/x 201 5" in log, f"request logged: {log!r}")
check("ERR(boom)" in log, "errors logged")
with open(os.path.join(cdir, "alpha.flows"), "rb") as fh:
    check(fh.read().count(b"FLOW") == 2, "flows written to the project's file")
mode = os.stat(os.path.join(cdir, "alpha.flows")).st_mode & 0o777
check(mode == 0o600, f"capture files are owner-only (mode {oct(mode)})")
check(not os.path.exists(os.path.join(cdir, "beta.log")), "nothing written for an idle project")

print("ok")
