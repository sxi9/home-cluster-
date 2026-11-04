# Session log

The design conversation that produced this repo, condensed. Original session:
https://claude.ai/code/session_01VFJFXmquTNfp8PDPL7CFZA (Claude Code, 2026-11-04).

## The ask
Pool the RAM of an Ubuntu laptop (head), a Windows laptop (booted into
Ubuntu), and rooted Android phones into one cluster to run a model that fits in
no single device, plus grouped services, with a dashboard. Easy setup on every
device. Wired preferred, Wi‑Fi as an option. GPUs of any brand, including
phone GPUs. Later: lots of Snapdragon phones; remote control of every device
from one place; maybe public access.

## Decisions, in the order they were made
1. Head owns all state; workers hold token + service units.
2. Wired LAN for model traffic, Tailscale for names/ssh/remote, static leases.
3. k3s: head = server, Ubuntu workers = agents.
4. llama.cpp RPC backend for the split; bigger not faster.
5. rpc-server as a systemd service on workers.
6. Build order: worker.sh + head.sh → service + `cluster run` → android.sh → dashboard.
7. Wi‑Fi accepted as a fallback; link type recorded and used by the planner.
8. One command per device: the head serves scripts, token and pins from
   clusterd on :8787; scripts find the head by baked URL, `cluster-head.local`,
   or Tailscale `head`; generic hostnames auto-named.
9. GPU: Vulkan default, CUDA/ROCm opt-in, Adreno OpenCL on Snapdragon.
   Phone GPUs add compute only (unified memory). CPU-vs-GPU on phones should be
   benchmarked per device; published results disagree.
10. Phones: native Termux for rpc-server + agent; chroot optional; k3s not
    possible on stock Android kernels.
11. Dashboard: one HTML file served by clusterd, live /api/state, tokens/sec
    from llama-server's metrics endpoint.
12. Additions: speculative decoding (`--draft`), Open WebUI on k3s
    (`cluster ui`), native Windows worker (worker.ps1, prebuilt releases),
    one controller (`cluster exec/restart/ssh` over the head's ssh key),
    remote access via Tailscale Serve/Funnel (`cluster share`).

## Research notes (partial; the search batch was interrupted)
- prima.cpp (ICLR 2026) targets heterogeneous low-resource home clusters, runs
  on Linux/macOS/Android, claims 5–17× lower latency than llama.cpp/exo/dllama.
- exo is the most popular pooling tool; ran out of memory on 70B in prima.cpp's
  comparison; Apple-leaning.
- DistAi pools Android phones + PCs over llama.cpp RPC with a split planner.
- No found project joins an iPhone to a Linux/Windows cluster; iOS needs a
  custom sideloaded app or a browser/WebRTC pool.
- Adreno OpenCL backend targets Snapdragon 8 Gen 3 / 8 Elite; one 2026 Termux
  benchmark found CPU faster than GPU for generation on 778G and 8 Gen 2.

## Open questions for the owner
- Head's LAN IP and Tailscale name (scripts discover it; confirm on first run).
- GPU in the Windows laptop? (decides `--gpu cuda` vs vulkan)
- USB‑C ethernet adapters for the phones?
- RAM to keep free per device (defaults: 2 GB laptops/phones, 4 GB Windows).
- Which Snapdragon chipsets (decides whether the Adreno path applies).
