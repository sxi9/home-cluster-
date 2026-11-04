#!/usr/bin/env python3
"""home-cluster node agent.

Runs on every node (head, Ubuntu worker, Termux phone). Standard library only.

  GET /metrics   JSON snapshot: RAM, CPU, GPU, temperature, battery, rpc-server
  heartbeat      the same snapshot POSTed to the head's clusterd every 10 s, so
                 `cluster run` and the dashboard know which devices are awake.

Settings come from the worker.env written by worker.sh / head.sh / android.sh
(path in $CLUSTER_ENV). Nothing here needs root.
"""
import json
import os
import platform
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HEARTBEAT_S = 10


def read_env(path):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    except OSError:
        pass
    return env


def default_env_path():
    for p in (os.environ.get("CLUSTER_ENV"),
              os.path.join(os.environ.get("PREFIX", ""), "etc/home-cluster/worker.env"),
              "/etc/home-cluster/worker.env", "/etc/home-cluster/head.env"):
        if p and os.path.exists(p):
            return p
    return "/etc/home-cluster/worker.env"


ENV = read_env(default_env_path())


def cfg(key, default=None):
    return os.environ.get(key) or ENV.get(key) or default


def sh(cmd, timeout=3):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def read_int(path):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def meminfo():
    out = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                out[k] = int(v.split()[0]) // 1024  # MB
    except OSError:
        pass
    return {
        "total_mb": out.get("MemTotal", 0),
        "free_mb": out.get("MemAvailable", out.get("MemFree", 0)),
        "swap_total_mb": out.get("SwapTotal", 0),
        "swap_free_mb": out.get("SwapFree", 0),
    }


def temperature_c():
    best = None
    base = "/sys/class/thermal"
    try:
        for z in os.listdir(base):
            if not z.startswith("thermal_zone"):
                continue
            t = read_int(os.path.join(base, z, "temp"))
            if t is None:
                continue
            c = t / 1000 if t > 1000 else float(t)
            if 0 < c < 150 and (best is None or c > best):
                best = round(c, 1)
    except OSError:
        pass
    return best


def battery():
    base = "/sys/class/power_supply"
    try:
        for d in os.listdir(base):
            p = os.path.join(base, d)
            try:
                with open(os.path.join(p, "type")) as f:
                    if f.read().strip() != "Battery":
                        continue
            except OSError:
                continue
            cap = read_int(os.path.join(p, "capacity"))
            status = ""
            try:
                with open(os.path.join(p, "status")) as f:
                    status = f.read().strip()
            except OSError:
                pass
            if cap is not None:
                return {"percent": cap, "charging": status in ("Charging", "Full"), "status": status}
    except OSError:
        pass
    return None


def gpu():
    kind = cfg("GPU", "cpu")
    info = {"kind": kind, "name": cfg("GPU_NAME", "") or None, "vram_total_mb": None,
            "vram_free_mb": None, "util_pct": None, "temp_c": None}
    q = sh(["nvidia-smi", "--query-gpu=name,memory.total,memory.used,utilization.gpu,temperature.gpu",
            "--format=csv,noheader,nounits"])
    if q:
        parts = [x.strip() for x in q.splitlines()[0].split(",")]
        if len(parts) == 5:
            try:
                total, used = int(float(parts[1])), int(float(parts[2]))
                info.update(name=parts[0], vram_total_mb=total, vram_free_mb=total - used,
                            util_pct=int(float(parts[3])), temp_c=int(float(parts[4])))
                return info
            except ValueError:
                pass
    # AMD / Intel expose VRAM through sysfs (amdgpu does; i915 partially)
    try:
        for c in sorted(os.listdir("/sys/class/drm")):
            if not c.startswith("card") or "-" in c:
                continue
            dev = os.path.join("/sys/class/drm", c, "device")
            total = read_int(os.path.join(dev, "mem_info_vram_total"))
            used = read_int(os.path.join(dev, "mem_info_vram_used"))
            busy = read_int(os.path.join(dev, "gpu_busy_percent"))
            if total:
                info.update(vram_total_mb=total // 2**20, vram_free_mb=(total - (used or 0)) // 2**20,
                            util_pct=busy)
                break
    except OSError:
        pass
    if kind != "cpu" and info["vram_total_mb"] is None:
        # unified memory (phones, iGPUs): the GPU shares system RAM
        info["unified"] = True
    return info


def rpc_listening(host, port):
    try:
        with socket.create_connection((host, int(port)), timeout=0.5):
            return True
    except (OSError, ValueError):
        return False


def is_android():
    return os.path.exists("/system/build.prop") or "ANDROID_ROOT" in os.environ or "com.termux" in sys.prefix


def device_model():
    if is_android():
        m = sh(["getprop", "ro.product.model"])
        soc = sh(["getprop", "ro.soc.model"]) or sh(["getprop", "ro.board.platform"])
        return " ".join(x for x in (m, soc) if x) or "android"
    for p in ("/sys/devices/virtual/dmi/id/product_name",):
        try:
            with open(p) as f:
                return f.read().strip()
        except OSError:
            pass
    return platform.node()


def snapshot():
    host = cfg("LAN_IP", "0.0.0.0")
    port = cfg("RPC_PORT", "50052")
    try:
        load1 = os.getloadavg()[0]
    except OSError:
        load1 = None
    try:
        with open("/proc/uptime") as f:
            uptime = int(float(f.read().split()[0]))
    except OSError:
        uptime = None
    return {
        "name": cfg("NODE_NAME", platform.node()),
        "role": cfg("ROLE", "worker"),
        "os": "android" if is_android() else platform.system().lower(),
        "model": device_model(),
        "arch": platform.machine(),
        "link": cfg("LINK_TYPE", "unknown"),
        "lan_ip": host,
        "agent_port": int(cfg("AGENT_PORT", "8788")),
        "cpus": os.cpu_count(),
        "load1": load1,
        "mem": meminfo(),
        "gpu": gpu(),
        "temp_c": temperature_c(),
        "battery": battery(),
        "rpc": {"port": int(port), "listening": rpc_listening(host, port),
                "mem_mb": int(cfg("RPC_MEM_MB", "0") or 0)},
        "llama_ref": cfg("LLAMA_REF", None),
        "uptime_s": uptime,
        "ts": time.time(),
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] in ("/", "/metrics", "/health"):
            body = json.dumps(snapshot()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def log_message(self, *args):  # quiet
        pass


def heartbeat_loop():
    url = cfg("JOIN_URL")
    if not url and cfg("HEAD"):
        url = "http://%s:8787" % cfg("HEAD")
    if not url:
        return
    url = url.rstrip("/") + "/api/heartbeat"
    while True:
        try:
            data = json.dumps(snapshot()).encode()
            req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=5).read()
        except Exception:  # head down, wifi flapping: try again next tick
            pass
        time.sleep(HEARTBEAT_S)


def main():
    if "--once" in sys.argv:
        print(json.dumps(snapshot(), indent=2))
        return
    port = int(cfg("AGENT_PORT", "8788"))
    bind = "0.0.0.0" if "--bind-all" in sys.argv else cfg("LAN_IP", "0.0.0.0")
    threading.Thread(target=heartbeat_loop, daemon=True).start()
    try:
        srv = ThreadingHTTPServer((bind, port), Handler)
    except OSError:
        srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)  # LAN IP changed; still serve
    srv.serve_forever()


if __name__ == "__main__":
    main()
