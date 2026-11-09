#!/usr/bin/env python3
"""clusterd: the head's one small service. Standard library only.

  GET  /                 dashboard (dashboard/index.html)
  GET  /api/state        nodes + current run + llama-server throughput
  GET  /api/nodes        nodes only
  POST /api/heartbeat    agents report here every 10 s
  GET  /worker.sh, /android.sh, /join.sh, /cluster-agent.py,
       /cluster.env, /token            the join directory, so a device joins
                                       with one curl | bash
  GET  /login, /logout   dashboard login (admin + the password set with
                         head.sh --admin-pass / cluster password). The CLI on
                         the head talks to /api/* from localhost without it.
  GET  /api/health       unauthenticated liveness, used by standby heads and agents
  GET  /api/role         primary | standby, and whether this instance is serving

Binds to the LAN address only (HEAD in head.env). The token is served in the
clear on the home LAN by design; keep the port firewalled to the LAN subnet.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AWAKE_S = 30          # a node is "awake" if it heartbeated within this many seconds
SESSION_S = 7 * 86400 # login lasts a week
JOIN_FILES = {"worker.sh", "android.sh", "join.sh", "worker.ps1", "cluster-agent.py", "cluster.env", "token", "head.pub", "home-cluster-worker.apk"}


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
BENCH_FILE = os.path.join(STATE_DIR, "bench.json")
TUNING_FILE = cfg("TUNING_FILE", "/etc/home-cluster/tuning.env")
FAILOVER_FILE = cfg("FAILOVER_FILE", "/var/lib/home-cluster/failover.json")
HEAD_ROLE = cfg("HEAD_ROLE", "primary")
PRIMARY_HEAD = cfg("PRIMARY_HEAD", cfg("HEAD", ""))
PASS_HASH = cfg("DASHBOARD_PASS_HASH", "")
ADMIN_USER = cfg("DASHBOARD_USER", "admin")
SECRET = (cfg("SESSION_SECRET") or secrets.token_hex(32)).encode()


# ----------------------------------------------------------------------------
# login: pbkdf2 password hash in head.env, HMAC-signed cookie, a week long
# ----------------------------------------------------------------------------
def hash_password(password, iterations=200000):
    salt = secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), iterations).hex()
    return "pbkdf2$%d$%s$%s" % (iterations, salt, h)


def check_password(password, stored):
    try:
        _, it, salt, h = stored.split("$")
        calc = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), int(it)).hex()
        return hmac.compare_digest(calc, h)
    except (ValueError, AttributeError):
        return False


def make_session():
    exp = str(int(time.time()) + SESSION_S)
    sig = hmac.new(SECRET, exp.encode(), "sha256").hexdigest()
    return "%s.%s" % (exp, sig)


def valid_session(cookie):
    try:
        exp, sig = cookie.split(".", 1)
        return int(exp) > time.time() and hmac.compare_digest(hmac.new(SECRET, exp.encode(), "sha256").hexdigest(), sig)
    except (ValueError, AttributeError):
        return False


LOGIN_HTML = """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>home-cluster login</title><style>
:root{color-scheme:light dark;--bg:#f4f4f2;--surface:#fcfcfb;--border:#dddcd6;--text:#0b0b0b;--text-2:#52514e;--accent:#2a78d6;--critical:#d03b3b}
@media(prefers-color-scheme:dark){:root{--bg:#121211;--surface:#1a1a19;--border:#2e2e2c;--text:#f0efec;--text-2:#c3c2b7;--accent:#3987e5}}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,sans-serif}
form{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:28px 28px 22px;width:min(92vw,340px)}
h1{font-size:18px;margin:0 0 4px}p{margin:0 0 18px;color:var(--text-2);font-size:13px}
label{display:block;font-size:12px;color:var(--text-2);margin:10px 0 4px}
input{width:100%%;box-sizing:border-box;padding:9px 10px;border:1px solid var(--border);border-radius:8px;background:var(--bg);color:var(--text);font:inherit}
button{margin-top:16px;width:100%%;padding:10px;border:0;border-radius:8px;background:var(--accent);color:#fff;font:inherit;font-weight:600;cursor:pointer}
.err{color:var(--critical);font-size:13px;margin-top:10px}</style></head><body>
<form method="post" action="/login"><h1>home-cluster</h1><p>%(head)s · sign in to the dashboard</p>
<label>user</label><input name="user" value="admin" autocomplete="username">
<label>password</label><input name="pass" type="password" autofocus autocomplete="current-password">
<button>Sign in</button>%(err)s</form></body></html>"""
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


def load_tuning():
    return read_env(TUNING_FILE)


def failover_state():
    st = load_json(FAILOVER_FILE, {})
    st.setdefault("active", HEAD_ROLE == "primary")
    return st


def standbys(node_list=None):
    """Standby heads, as join URLs, awake ones first."""
    out = []
    for n in node_list if node_list is not None else nodes():
        if n.get("standby") and n.get("lan_ip"):
            out.append({"name": n["name"], "url": "http://%s:%s" % (n["lan_ip"], cfg("CLUSTERD_PORT", "8787")),
                        "awake": n.get("awake", False), "ready": bool(n.get("standby_ready"))})
    out.sort(key=lambda s: (not s["awake"], not s["ready"], s["name"]))
    return out


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
    nl = nodes()
    return {"ts": time.time(), "head": cfg("NODE_NAME", "head"), "nodes": nl, "run": run,
            "llama": llama, "bench": load_json(BENCH_FILE, {}), "tuning": load_tuning(),
            "role": HEAD_ROLE, "primary": PRIMARY_HEAD, "standbys": standbys(nl), "failover": failover_state(),
            "auth": bool(PASS_HASH), "llama_url": "http://%s:%s" % (cfg("HEAD", "head"), cfg("LLAMA_PORT", "8080"))}


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


class Handler(BaseHTTPRequestHandler):
    server_version = "clusterd/1"

    PROTECTED = ("/", "/index.html", "/api/state", "/api/nodes", "/api/role")

    def logged_in(self):
        if not PASS_HASH:
            return True
        c = self.headers.get("Cookie", "")
        for part in c.split(";"):
            k, _, v = part.strip().partition("=")
            if k == "hc_session" and valid_session(v):
                return True
        return False

    def allowed(self, path):
        if path not in self.PROTECTED:
            return True
        if path.startswith("/api/") and self.client_address[0] in ("127.0.0.1", "::1"):
            return True      # the cluster CLI on the head
        return self.logged_in()

    def _redirect(self, to, cookie=None):
        self.send_response(302)
        self.send_header("Location", to)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", "0")
        self.end_headers()

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
        if path == "/login":
            if not PASS_HASH:
                return self._redirect("/")
            err = '<div class="err">wrong user or password</div>' if "err" in self.path else ""
            return self._send(200, LOGIN_HTML % {"head": cfg("NODE_NAME", "head"), "err": err}, "text/html; charset=utf-8")
        if path == "/logout":
            return self._redirect("/login", "hc_session=; Path=/; Max-Age=0")
        if path == "/api/health":
            return self._send(200, {"ok": True, "role": HEAD_ROLE, "name": cfg("NODE_NAME", "head"),
                                    "active": failover_state().get("active", True), "ts": time.time()})
        if path == "/api/role":
            st = failover_state()
            return self._send(200, {"role": HEAD_ROLE, "primary": PRIMARY_HEAD, "active": st.get("active", True),
                                    "since": st.get("since"), "standbys": standbys()})
        if not self.allowed(path):
            if path.startswith("/api/"):
                return self._send(401, {"error": "login required"})
            return self._redirect("/login")
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
            if name.endswith(".apk"):
                return self._send(200, body, "application/vnd.android.package-archive")
            if name.endswith(".ps1"):
                me = cfg("JOIN_URL") or "http://%s:%s" % (cfg("HEAD", self.server.server_address[0]), cfg("CLUSTERD_PORT", "8787"))
                body = body.replace(b'$JoinUrlDefault = ""', ('$JoinUrlDefault = "%s"' % me).encode(), 1)
            if name.endswith(".sh"):
                # bake this head's address into the script, so `curl | bash` needs no flags
                # even on phones, which cannot resolve .local names
                me = cfg("JOIN_URL") or "http://%s:%s" % (cfg("HEAD", self.server.server_address[0]), cfg("CLUSTERD_PORT", "8787"))
                body = body.replace(b'JOIN_URL_DEFAULT=""', ('JOIN_URL_DEFAULT="%s"' % me).encode(), 1)
            return self._send(200, body, "text/plain; charset=utf-8")
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/login":
            n = int(self.headers.get("Content-Length", "0"))
            form = urllib.parse.parse_qs(self.rfile.read(min(n, 4096)).decode(errors="replace"))
            user = (form.get("user") or [""])[0]
            pw = (form.get("pass") or [""])[0]
            if PASS_HASH and hmac.compare_digest(user, ADMIN_USER) and check_password(pw, PASS_HASH):
                return self._redirect("/", "hc_session=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Lax" % (make_session(), SESSION_S))
            time.sleep(0.5)      # slow down guessing
            return self._redirect("/login?err=1")
        if path != "/api/heartbeat":
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
        # tell the agent where to go if this head disappears
        return self._send(200, {"ok": True, "role": HEAD_ROLE, "primary": PRIMARY_HEAD,
                                "fallbacks": [s["url"] for s in standbys() if s["name"] != name]})

    def log_message(self, *args):
        pass


def main():
    if "--hash" in sys.argv:          # used by head.sh / cluster password
        print(hash_password(sys.argv[sys.argv.index("--hash") + 1]))
        return
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
