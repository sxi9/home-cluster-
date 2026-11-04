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

## Learned from the real llama.cpp build (2026-11, tag b12098)
- The rpc binary is `ggml-rpc-server` (older tags: `rpc-server`); scripts detect
  via `cmake --build build --target help` and install it as `rpc-server`.
- `rpc-server` has no `--mem` any more; RPC_MEM_MB is a planner-side cap only.
- RPC devices are named `RPC0, RPC1…` in `--rpc` order (older: `RPC[host:port]`);
  `cluster run` resolves names with `llama-server --rpc ... --list-devices`.
- Speculative flags: `--spec-draft-n-max/min` (older `--draft-max/min`);
  mmap/mlock: `--load-mode` (older `--mlock/--no-mmap`). `server_has()` detects.
- Default build is shared libs: always `-DBUILD_SHARED_LIBS=OFF`.
- llama-server no longer logs per-device buffer sizes at default verbosity;
  `cluster run` estimates them (`buffer_estimated`).
- rpc-server serves one client at a time: never probe it with a TCP connect
  mid-run; the agent reads /proc/net/tcp instead.

## Testing reality
The model path was verified for real in the cloud container (real rpc-servers,
real llama-server, real model). The install scripts (systemd, k3s, NFS,
Tailscale, Termux) have only been dry-run; worker.ps1 is unchecked (no
PowerShell here). First real hardware test: the two laptops.

## Layout
join.sh, head.sh, worker.sh, android.sh, worker.ps1 · bin/cluster ·
head/clusterd.py · dashboard/index.html · agent/cluster-agent.py ·
k8s/open-webui.yaml · tests/smoke.sh · docs/ · CHECKLIST.md
