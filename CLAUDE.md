# home-cluster — notes for Claude (and humans) working in this repo

Read this first. It is the memory of how the project was designed and why.

## What this is
A home compute cluster: Ubuntu head + Ubuntu laptops + rooted Snapdragon phones
(Termux) + optionally native Windows PCs, pooling RAM/GPUs to run one GGUF
model with llama.cpp's RPC backend, k3s for grouped services, one dashboard.
Owner: sxi9. Design history: docs/SESSION-LOG.md.

## Fixed decisions (do not re-litigate)
- The head owns all shared state (models, token, NFS, pins, dashboard). Workers
  hold a config file, a token and services; a wiped device rejoins with one
  command.
- Wired LAN preferred, Wi‑Fi accepted as a slower fallback; Tailscale for
  names/ssh/remote. Static DHCP leases.
- llama.cpp RPC for the model split (bigger, not faster). The head pins the
  llama.cpp commit (and tag) and every worker builds/downloads that exact one.
- Setup on every device is a single pasted command served by the head
  (`clusterd` on :8787). Served scripts get the head's URL baked in
  (`JOIN_URL_DEFAULT=""` / `$JoinUrlDefault = ""` lines are templated).
- Phones run rpc-server + agent natively in Termux, not in a chroot. k3s does
  not run on stock Android; the chroot is optional/experimental.
- Vulkan is the default GPU backend on PCs; CUDA/ROCm opt-in; Adreno OpenCL on
  Snapdragon.
- No external dependencies anywhere: bash + python3 stdlib + one HTML file.

## Conventions
- Every script is idempotent, has `--dry-run` and `--leave`, saves its settings
  (`/etc/home-cluster/*.env`, `$PREFIX/etc/home-cluster/worker.env` on Termux)
  and reloads them on a flagless re-run. Precedence: flags > head pins > saved
  > defaults.
- `set -euo pipefail` everywhere: never end a function on a test that can fail
  (`[[ ]] && ...` as the last statement kills the script); add `return 0`.
- Config keys are shared across scripts/agent/CLI: NODE_NAME, HEAD, JOIN_URL,
  LAN_IP, LINK_TYPE, RPC_PORT, RPC_MEM_MB, GPU, GPU_NAME, AGENT_PORT, LLAMA_REF.
- Dashboard colours follow the validated palette in dashboard/index.html
  (categorical slots in fixed order; status colours reserved).
- Keep shellcheck clean (`shellcheck -S style`), `python3 -m py_compile`, and
  `bash tests/smoke.sh` green before pushing. CI runs the same.

## Testing reality
Nothing has run on real hardware yet. Dry runs use a fake `ip` shim; the smoke
test uses fake heartbeats and a fake llama-server. worker.ps1 has not been
syntax-checked (no PowerShell here). First real test: the two laptops.

## Layout
join.sh, head.sh, worker.sh, android.sh, worker.ps1 · bin/cluster ·
head/clusterd.py · dashboard/index.html · agent/cluster-agent.py ·
k8s/open-webui.yaml · tests/smoke.sh · docs/ · CHECKLIST.md
