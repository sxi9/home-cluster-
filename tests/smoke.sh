#!/usr/bin/env bash
# Smoke test: no root, no network, no real llama.cpp. Starts clusterd and the
# agent against a temp dir, feeds fake heartbeats, plans and "runs" a synthetic
# GGUF against a fake llama-server, and checks what the dashboard API reports.
#   bash tests/smoke.sh
# shellcheck disable=SC2015  # ok() never fails, so `A && ok || fail` reads as intended
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d); trap 'pkill -f "clusterd.py$" >/dev/null 2>&1 || true; pkill -f "cluster-agent.py$" >/dev/null 2>&1 || true; pkill -f "fake-llama-server" >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
PORT_D=18787 PORT_A=18788 PORT_L=18080
mkdir -p "$T"/{state/nodes,join,logs,models,bin}

# synthetic GGUF: qwen2 arch, 48 layers, 12 GB sparse
python3 - "$T/models/test-24b-q4.gguf" <<'PY'
import struct, sys
def s(x): b=x.encode(); return struct.pack('<Q',len(b))+b
kv=[("general.architecture",8,s("qwen2")),("general.name",8,s("Test-24B-Q4_K_M")),("qwen2.block_count",4,struct.pack('<I',48)),
    ("qwen2.embedding_length",4,struct.pack('<I',5120)),("qwen2.attention.head_count",4,struct.pack('<I',40)),
    ("qwen2.attention.head_count_kv",4,struct.pack('<I',8)),("tokenizer.ggml.tokens",9,struct.pack('<IQ',8,0))]
hdr=b"GGUF"+struct.pack('<IQQ',3,1,len(kv))+b"".join(s(k)+struct.pack('<I',t)+v for k,t,v in kv)
with open(sys.argv[1],"wb") as f: f.write(hdr); f.truncate(12*2**30)
PY

cat > "$T/bin/llama-server" <<'EOF2'
#!/usr/bin/env bash
# fake-llama-server
if [[ $1 == --list-devices ]]; then printf 'Available devices:\n  Vulkan0: Test GPU (8192 MiB, 7000 MiB free)\n'; exit 0; fi
exec python3 - "$@" <<'PY'
import sys, time, http.server
a=sys.argv[1:]; devs=a[a.index('--device')+1].split(',') if '--device' in a else []
for d in devs: print("load_tensors: %s model buffer size = 2048.00 MiB" % d)
print("load_tensors: offloaded %s/49 layers to GPU" % a[a.index('-ngl')+1], flush=True)
port=int(a[a.index('--port')+1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b=b'{"status":"ok"}' if self.path=='/health' else b"llamacpp:predicted_tokens_seconds 4.20\nllamacpp:prompt_tokens_seconds 55.0\n"
        self.send_response(200); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*x): pass
http.server.ThreadingHTTPServer(('127.0.0.1',port),H).serve_forever()
PY
EOF2
chmod +x "$T/bin/llama-server"

cat > "$T/head.env" <<EOF2
NODE_NAME=head
ROLE=head
HEAD=127.0.0.1
LAN_IP=127.0.0.1
LINK_TYPE=wired
GPU=vulkan
CLUSTER_ROOT=$T
STATE_DIR=$T/state
LOG_DIR=$T/logs
MODELS_DIR=$T/models
JOIN_DIR=$T/join
LLAMA_BIN=$T/bin
LLAMA_PORT=$PORT_L
CLUSTERD_PORT=$PORT_D
AGENT_PORT=$PORT_A
JOIN_URL=http://127.0.0.1:$PORT_D
DASHBOARD_HTML=$REPO/dashboard/index.html
EOF2
cp "$REPO"/worker.sh "$T/join/"; echo "K10token" > "$T/join/token"
CLUSTER_ENV=$T/head.env python3 "$REPO/head/clusterd.py" & 
CLUSTER_ENV=$T/head.env python3 "$REPO/agent/cluster-agent.py" &
sleep 1.5

ok() { printf '  \033[32mok\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

# 1. join files + templating + traversal
curl -fsS "http://127.0.0.1:$PORT_D/worker.sh" | grep -q "^JOIN_URL_DEFAULT=\"http://127.0.0.1:$PORT_D\"" && ok "served worker.sh carries the head URL" || fail "templating"
[[ $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT_D/../head.env") == 404 ]] && ok "no path traversal" || fail "traversal"
[[ $(curl -fsS "http://127.0.0.1:$PORT_D/token") == K10token ]] && ok "token served" || fail "token"

# 2. heartbeats
hb() { curl -fsS -X POST -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$PORT_D/api/heartbeat" >/dev/null; }
hb '{"name":"laptop2","role":"worker","link":"wired","lan_ip":"127.0.0.1","agent_port":1,"mem":{"total_mb":32000,"free_mb":28000},"gpu":{"kind":"vulkan","vram_total_mb":8192,"vram_free_mb":7900},"rpc":{"port":50052,"listening":true,"mem_mb":30000}}'
hb '{"name":"phone-a","role":"worker","link":"wifi","lan_ip":"127.0.0.1","agent_port":1,"mem":{"total_mb":16000,"free_mb":9800},"gpu":{"kind":"opencl","unified":true},"rpc":{"port":50053,"listening":true,"mem_mb":12000},"temp_c":61}'
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{"name":"../x"}' "http://127.0.0.1:$PORT_D/api/heartbeat") == 400 ]] && ok "bad node name rejected" || fail "name validation"
sleep 1
n=$(curl -fsS "http://127.0.0.1:$PORT_D/api/nodes" | python3 -c 'import json,sys; print(len([x for x in json.load(sys.stdin) if x["awake"]]))')
[[ $n == 3 ]] && ok "3 awake nodes (head agent + 2 fake workers)" || fail "expected 3 awake nodes, got $n"

# 3. plan: wired first, wifi only when needed
export CLUSTER_ENV=$T/head.env
"$REPO/bin/cluster" plan test-24b-q4.gguf --ctx 4096 | tee "$T/plan.txt"
grep -q "laptop2 *wired" "$T/plan.txt" && ok "wired worker in plan" || fail "laptop2 missing from plan"
grep -q "phone-a" "$T/plan.txt" && ok "wifi phone pulled in because the model needs it" || fail "phone-a missing"
"$REPO/bin/cluster" plan test-24b-q4.gguf --ctx 4096 --exclude phone-a | grep -q "stay on the head" && ok "--exclude honoured, remainder on head CPU" || fail "exclude"

# 4. run against the fake server
"$REPO/bin/cluster" run test-24b-q4.gguf --ctx 4096 | grep -q "^running" && ok "cluster run reached running" || fail "run"
st=$(curl -fsS "http://127.0.0.1:$PORT_D/api/state")
python3 - "$st" <<'PY' && ok "api/state has run + throughput + buffers" || fail "api/state"
import json,sys; s=json.loads(sys.argv[1]); r=s["run"]
assert r["status"]=="running" and s["llama"]["gen_tps"]==4.2, s["llama"]
assert any(d.get("buffer_mb")==2048 for d in r["devices"]), r["devices"]
PY
"$REPO/bin/cluster" status | grep -q "4.2 tok/s" && ok "cluster status shows throughput" || fail "status"
"$REPO/bin/cluster" stop | grep -q stopped && ok "cluster stop" || fail "stop"
echo "smoke test passed"
