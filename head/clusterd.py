#!/usr/bin/env python3
"""clusterd: the head's one small service. Standard library only.

  GET  /                 dashboard (dashboard/index.html)
  GET  /api/state        nodes + current run + llama-server throughput
  GET  /api/nodes        nodes only
  POST /api/heartbeat    agents report here every 10 s
  GET  /worker.sh, /android.sh, /join.sh, /cluster-agent.py,
       /cluster.env, /token            the join directory, so a device joins
                                       with one curl | bash

Binds to the LAN address only (HEAD in head.env). The token is served in the
clear on the home LAN by design; keep the port firewalled to the LAN subnet.
"""
import json
import os
import re
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AWAKE_S = 30          # a node is "awake" if it heartbeated within this many seconds
JOIN_FILES = {"worker.sh", "android.sh", "join.sh", "cluster-agent.py", "cluster.env", "token"}


def read_env(path):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip()
    except OSError:
        pass
    return env


ENV = read_env(os.environ.get("CLUSTER_ENV", "/etc/home-cluster/head.env"))


def cfg(key, default=None):
    return os.environ.get(key) or ENV.get(key) or default


ROOT = cfg("CLUSTER_ROOT", "/srv/cluster")
JOIN_DIR = cfg("JOIN_DIR", os.path.join(ROOT, "join"))
STATE_DIR = cfg("STATE_DIR", os.path.join(ROOT, "state"))
NODES_DIR = os.path.join(STATE_DIR, "nodes")
RUN_FILE = os.path.join(STATE_DIR, "run.json")
HTML = cfg("DASHBOARD_HTML", os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html"))
LLAMA_URL = cfg("LLAMA_URL", "http://127.0.0.1:%s" % cfg("LLAMA_PORT", "8080"))
NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def nodes():
    out = []
    now = time.time()
    try:
        names = sorted(os.listdir(NODES_DIR))
    except OSError:
        names = []
    for fn in names:
        if not fn.endswith(".json"):
            continue
        n = load_json(os.path.join(NODES_DIR, fn), None)
        if not n:
            continue
        n["age_s"] = round(now - n.get("last_seen", 0))
        n["awake"] = n["age_s"] <= AWAKE_S
        out.append(n)
    out.sort(key=lambda n: (n.get("role") != "head", not n["awake"], n.get("name", "")))
    return out


PROM_RE = re.compile(r"^(llamacpp:[a-z_]+)\s+([-+0-9.eE]+)", re.M)


def llama_metrics():
    """Scrape llama-server's Prometheus endpoint (needs --metrics)."""
    try:
        with urllib.request.urlopen(LLAMA_URL + "/metrics", timeout=1.5) as r:
            text = r.read().decode()
    except Exception:
        return None
    m = {k: float(v) for k, v in PROM_RE.findall(text)}
    return {
        "gen_tps": m.get("llamacpp:predicted_tokens_seconds"),
        "prompt_tps": m.get("llamacpp:prompt_tokens_seconds"),
        "tokens_predicted": m.get("llamacpp:tokens_predicted_total"),
        "tokens_prompt": m.get("llamacpp:prompt_tokens_total"),
        "requests_processing": m.get("llamacpp:requests_processing"),
        "kv_cache_ratio": m.get("llamacpp:kv_cache_usage_ratio"),
        "up": True,
    }


def state():
    run = load_json(RUN_FILE, None)
    llama = llama_metrics()
    if run and run.get("status") == "running" and llama is None:
        run["status"] = "loading" if run.get("pid") and pid_alive(run["pid"]) else "stopped"
    return {"ts": time.time(), "head": cfg("NODE_NAME", "head"), "nodes": nodes(), "run": run,
            "llama": llama, "llama_url": "http://%s:%s" % (cfg("HEAD", "head"), cfg("LLAMA_PORT", "8080"))}


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


class Handler(BaseHTTPRequestHandler):
    server_version = "clusterd/1"

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            try:
                with open(HTML, "rb") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            except OSError:
                return self._send(404, {"error": "dashboard html missing"})
        if path == "/api/state":
            return self._send(200, state())
        if path == "/api/nodes":
            return self._send(200, nodes())
        name = path.lstrip("/")
        if name in JOIN_FILES:
            try:
                with open(os.path.join(JOIN_DIR, name), "rb") as f:
                    body = f.read()
            except OSError:
                return self._send(404, {"error": "%s not published yet" % name})
            if name.endswith(".sh"):
                # bake this head's address into the script, so `curl | bash` needs no flags
                # even on phones, which cannot resolve .local names
                me = cfg("JOIN_URL") or "http://%s:%s" % (cfg("HEAD", self.server.server_address[0]), cfg("CLUSTERD_PORT", "8787"))
                body = body.replace(b'JOIN_URL_DEFAULT=""', ('JOIN_URL_DEFAULT="%s"' % me).encode(), 1)
            return self._send(200, body, "text/plain; charset=utf-8")
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/api/heartbeat":
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            data = json.loads(self.rfile.read(min(n, 65536)) or b"{}")
            name = str(data.get("name", ""))
            if not NAME_RE.match(name):
                raise ValueError("bad name")
        except (ValueError, TypeError) as e:
            return self._send(400, {"error": str(e)})
        data["last_seen"] = time.time()
        data["remote_ip"] = self.client_address[0]
        save_json(os.path.join(NODES_DIR, name + ".json"), data)
        return self._send(200, {"ok": True})

    def log_message(self, *args):
        pass


def main():
    port = int(cfg("CLUSTERD_PORT", "8787"))
    bind = "0.0.0.0" if "--bind-all" in sys.argv else cfg("HEAD", "0.0.0.0")
    os.makedirs(NODES_DIR, exist_ok=True)
    try:
        srv = ThreadingHTTPServer((bind, port), Handler)
    except OSError:
        srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    srv.serve_forever()


if __name__ == "__main__":
    main()
