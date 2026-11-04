#!/usr/bin/env python3
"""cluster-failover: runs on a STANDBY head. Watches the primary; when it has been
unreachable for a while, promotes this machine (starts clusterd + the mDNS alias so
the dashboard, join files and `cluster run` work here); when the primary is back,
steps down again. Manual `cluster failover promote|demote` pins the state until
`cluster failover auto`.

State: /var/lib/home-cluster/failover.json  {active, since, reason, manual}
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

ENV_FILE = os.environ.get("CLUSTER_ENV", "/etc/home-cluster/head.env")


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


ENV = read_env(ENV_FILE)
cfg = lambda k, d=None: os.environ.get(k) or ENV.get(k) or d
PRIMARY = cfg("PRIMARY_HEAD")
PORT = cfg("CLUSTERD_PORT", "8787")
STATE = cfg("FAILOVER_FILE", "/var/lib/home-cluster/failover.json")
CHECK_S = int(cfg("FAILOVER_CHECK_S", "10"))
DOWN_AFTER = int(cfg("FAILOVER_DOWN_CHECKS", "4"))     # 4 x 10 s = promote after ~40 s of silence
UP_AFTER = int(cfg("FAILOVER_UP_CHECKS", "3"))
SERVICES = ["clusterd", "cluster-mdns"]


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def primary_up():
    try:
        with urllib.request.urlopen("http://%s:%s/api/health" % (PRIMARY, PORT), timeout=4) as r:
            return json.load(r).get("ok") is True
    except Exception:
        return False


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"active": False}


def save_state(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE + ".tmp", "w") as f:
        json.dump(st, f)
    os.replace(STATE + ".tmp", STATE)


def set_services(up):
    subprocess.run(["systemctl", "start" if up else "stop"] + SERVICES, capture_output=True)


def main():
    if not PRIMARY:
        log("no PRIMARY_HEAD in %s; nothing to watch" % ENV_FILE)
        sys.exit(1)
    st = load_state()
    set_services(st.get("active", False))     # restore last state on boot
    down = up = 0
    log("watching primary %s (promote after %d missed checks)" % (PRIMARY, DOWN_AFTER))
    while True:
        ok = primary_up()
        st = load_state()
        if st.get("manual"):
            time.sleep(CHECK_S)
            continue
        if ok:
            up += 1
            down = 0
            if st.get("active") and up >= UP_AFTER:
                log("primary is back; standing down")
                set_services(False)
                save_state({"active": False, "since": time.time(), "reason": "primary back"})
        else:
            down += 1
            up = 0
            if not st.get("active") and down >= DOWN_AFTER:
                log("primary silent for %d checks; PROMOTING this standby" % down)
                set_services(True)
                save_state({"active": True, "since": time.time(), "reason": "primary %s unreachable" % PRIMARY})
        time.sleep(CHECK_S)


if __name__ == "__main__":
    main()
