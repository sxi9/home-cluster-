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


def port_listening(port):
    """Is anything LISTENing on this TCP port? Read from the kernel socket table, so the
    check does not open a connection (rpc-server serves one client at a time and a probe
    connection would otherwise sit in its backlog mid-run)."""
    want = "%04X" % int(port)
    found = False
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(table) as f:
                next(f)
                for line in f:
                    parts = line.split()
                    if len(parts) > 3 and parts[1].rsplit(":", 1)[1] == want and parts[3] == "0A":
                        return True
                found = True
        except (OSError, StopIteration, IndexError, ValueError):
            continue
    return False if found else None   # None: table not readable (Android 10+ for non-root apps)


def rpc_listening(host, port):
    state = port_listening(port)
    if state is not None:
        return state
    try:
        with socket.create_connection((host, int(port)), timeout=0.5):
            return True
    except (OSError, ValueError):
        # could not connect: busy serving the current run, or really down
        return any(n.startswith(("rpc-server", "ggml-rpc-server")) for n in process_names())


def process_names():
    out = []
    try:
        for pid in os.listdir("/proc"):
            if pid.isdigit():
                try:
                    with open("/proc/%s/comm" % pid) as f:
                        out.append(f.read().strip())
                except OSError:
                    pass
    except OSError:
        pass
    return out


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


# JEDEC manufacturer ids for MMC/SD (eMMC chips and SD cards)
MMC_VENDORS = {0x02: "Kingston/Toshiba", 0x03: "SanDisk", 0x11: "Toshiba/Kioxia", 0x13: "Micron", 0x15: "Samsung",
               0x1b: "Samsung", 0x27: "Phison", 0x28: "Lexar", 0x45: "SanDisk", 0x70: "Kingston", 0x74: "Transcend",
               0x90: "SK Hynix", 0xfe: "Micron", 0x9f: "Kingston", 0x82: "Sony", 0x41: "Kingston"}


def read_str(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def cpu_info():
    model = ""
    if is_android():
        soc = sh(["getprop", "ro.soc.model"])
        manu = sh(["getprop", "ro.soc.manufacturer"])
        model = " ".join(x for x in (manu, soc) if x) or sh(["getprop", "ro.hardware"])
    if not model:
        try:
            with open("/proc/cpuinfo") as f:
                for line in f:
                    if line.lower().startswith(("model name", "hardware")):
                        model = line.split(":", 1)[1].strip()
                        break
        except OSError:
            pass
    mhz = read_int("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
    # big.LITTLE phones: report the fastest cluster
    try:
        for c in os.listdir("/sys/devices/system/cpu"):
            if c.startswith("cpu") and c[3:].isdigit():
                m = read_int("/sys/devices/system/cpu/%s/cpufreq/cpuinfo_max_freq" % c)
                if m and (mhz is None or m > mhz):
                    mhz = m
    except OSError:
        pass
    return {"model": model or platform.processor() or platform.machine(), "cores": os.cpu_count(),
            "max_mhz": mhz // 1000 if mhz else None, "arch": platform.machine()}


def mounts():
    """device -> (mountpoint, fstype) from /proc/mounts, first mount wins."""
    out = {}
    try:
        with open("/proc/mounts") as f:
            for line in f:
                dev, mp, fs = line.split()[:3]
                out.setdefault(os.path.realpath(dev) if dev.startswith("/dev/") else dev, (mp, fs))
    except OSError:
        pass
    return out


def free_gb(path):
    try:
        st = os.statvfs(path)
        return round(st.f_bavail * st.f_frsize / 2**30, 1)
    except OSError:
        return None


def storage_info():
    """Every physical block device: kind (NVMe SSD / SSD / HDD / eMMC / UFS / SD card), vendor, model, size, free."""
    out = []
    mts = mounts()
    try:
        blocks = sorted(os.listdir("/sys/block"))
    except OSError:
        return out
    for b in blocks:
        if b.startswith(("loop", "ram", "zram", "dm-", "md", "sr", "fd", "nbd")):
            continue
        base = "/sys/block/" + b
        size = read_int(base + "/size")
        if not size or size * 512 < 2**30:
            continue
        dev = base + "/device"
        link = os.path.realpath(dev) if os.path.exists(dev) else ""
        rot = read_int(base + "/queue/rotational")
        vendor = read_str(dev + "/vendor")
        if vendor.startswith("0x"):
            vendor = {"0x1af4": "virtio", "0x144d": "Samsung", "0x15b7": "SanDisk/WD", "0x1c5c": "SK Hynix", "0x1e0f": "Kioxia", "0x8086": "Intel", "0xc0a9": "Micron/Crucial", "0x1987": "Phison", "0x126f": "Silicon Motion"}.get(vendor.lower(), vendor)
        model = read_str(dev + "/model") or read_str(dev + "/name")
        kind = "disk"
        if b.startswith("nvme"):
            kind = "NVMe SSD"
            vendor = vendor or ""
        elif b.startswith("mmcblk"):
            t = read_str(dev + "/type").upper()
            kind = {"MMC": "eMMC", "SD": "SD card", "SDIO": "SDIO"}.get(t, "MMC")
            manf = read_str(dev + "/manfid")
            try:
                vendor = MMC_VENDORS.get(int(manf, 16), vendor or manf)
            except ValueError:
                pass
            if not model:
                model = read_str(dev + "/name")
        elif "ufs" in link.lower() or "ufshc" in link.lower():
            kind = "UFS"
        elif b.startswith(("sd", "vd", "xvd")):
            kind = "HDD" if rot == 1 else "SSD"
            if "usb" in link.lower():
                kind += " (USB)"
        # find a mount on this device or one of its partitions
        mp = None
        for d, (m, fs) in mts.items():
            if d.startswith("/dev/" + b):
                if mp is None or m in ("/", "/data"):
                    mp = m
        entry = {"dev": b, "kind": kind, "vendor": vendor.strip(), "model": model.strip(),
                 "size_gb": round(size * 512 / 2**30, 1), "mount": mp, "free_gb": free_gb(mp) if mp else None}
        out.append(entry)
    if is_android():
        # user storage lives on /data; external cards show up under /storage/XXXX-XXXX
        if out and all(e["free_gb"] is None for e in out):
            out[0]["mount"], out[0]["free_gb"] = "/data", free_gb("/data")
        try:
            for d in os.listdir("/storage"):
                if d not in ("emulated", "self") and os.path.ismount("/storage/" + d):
                    card = next((e for e in out if e["kind"] == "SD card"), None)
                    if card:
                        card["mount"], card["free_gb"] = "/storage/" + d, free_gb("/storage/" + d)
                    else:
                        st = os.statvfs("/storage/" + d)
                        out.append({"dev": d, "kind": "SD card", "vendor": "", "model": "", "mount": "/storage/" + d,
                                    "size_gb": round(st.f_blocks * st.f_frsize / 2**30, 1), "free_gb": free_gb("/storage/" + d)})
        except OSError:
            pass
    return out


_LAST_PROC = {}      # pid -> (cpu_ticks, wall)
CLUSTER_PROCS = ("rpc-server", "ggml-rpc-server", "llama-server", "cluster-agent", "clusterd", "k3s", "containerd")


def processes(limit=8):
    """Top processes by memory, with CPU% since the last call. /proc only, no psutil."""
    global _LAST_PROC
    hz = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
    now = time.time()
    page = os.sysconf("SC_PAGE_SIZE") if hasattr(os, "sysconf") else 4096
    seen, out = {}, []
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return []
    for pid in pids:
        try:
            with open("/proc/%s/stat" % pid) as f:
                st = f.read()
            name = st[st.index("(") + 1:st.rindex(")")]
            fields = st[st.rindex(")") + 2:].split()
            ticks = int(fields[11]) + int(fields[12])          # utime + stime
            rss_mb = int(fields[21]) * page // 2**20
        except (OSError, ValueError, IndexError):
            continue
        if rss_mb < 8:
            continue
        cpu = None
        last = _LAST_PROC.get(pid)
        if last:
            dt = now - last[1]
            if dt > 0:
                cpu = round(100.0 * (ticks - last[0]) / hz / dt, 1)
        seen[pid] = (ticks, now)
        out.append({"pid": int(pid), "name": name[:24], "rss_mb": rss_mb, "cpu_pct": cpu,
                    "cluster": any(name.startswith(c) for c in CLUSTER_PROCS)})
    _LAST_PROC = seen
    out.sort(key=lambda p: -p["rss_mb"])
    return out[:limit]


def alerts(procs, mem):
    """Things a person would want to know: a non-cluster process hogging RAM or CPU."""
    out = []
    total = mem.get("total_mb") or 1
    for p in procs:
        if p["cluster"]:
            continue
        if p["rss_mb"] > total * 0.25:
            out.append("%s uses %d MB RAM (%d%%)" % (p["name"], p["rss_mb"], 100 * p["rss_mb"] // total))
        elif (p["cpu_pct"] or 0) > 80:
            out.append("%s uses %d%% CPU" % (p["name"], p["cpu_pct"]))
    if mem.get("total_mb") and mem.get("free_mb") is not None and mem["free_mb"] < total * 0.08:
        out.append("low memory: %d MB free" % mem["free_mb"])
    return out[:4]


def ssh_hint():
    if is_android():
        return {"user": "termux", "port": 8022}
    if platform.system().lower() == "linux":
        return {"user": "root", "port": 22}
    return None


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
        "cpu": cpu_info(),
        "storage": storage_info(),
        "processes": (procs := processes()),
        "alerts": alerts(procs, (m := meminfo())),
        "ssh": ssh_hint(),
        "load1": load1,
        "mem": m,
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
        path = self.path.split("?")[0]
        if path == "/processes":
            body = json.dumps(processes(limit=25)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path in ("/", "/metrics", "/health"):
            body = json.dumps(snapshot()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        # bandwidth probe from the head: body is discarded, byte count returned
        if self.path.split("?")[0] == "/sink":
            n = int(self.headers.get("Content-Length", "0"))
            left = n
            while left > 0:
                chunk = self.rfile.read(min(left, 1 << 20))
                if not chunk:
                    break
                left -= len(chunk)
            body = json.dumps({"bytes": n - left}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
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
