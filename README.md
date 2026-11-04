# home-cluster

[![ci](https://github.com/sxi9/home-cluster-/actions/workflows/ci.yml/badge.svg)](https://github.com/sxi9/home-cluster-/actions/workflows/ci.yml)
![platforms](https://img.shields.io/badge/devices-Ubuntu%20%C2%B7%20Android%20(Termux)-blue)
![gpu](https://img.shields.io/badge/GPU-Vulkan%20%C2%B7%20CUDA%20%C2%B7%20ROCm%20%C2%B7%20Adreno%20OpenCL-green)
![status](https://img.shields.io/badge/status-not%20yet%20run%20on%20real%20hardware-orange)

Pool the RAM, GPUs and CPUs of the laptops and phones you already own into one
cluster, run a language model that is too big for any single device, and watch
it all on one dashboard.

![dashboard](docs/screenshots/dashboard-dark.png)

## How it works

```
                 wired LAN (model traffic)  ·  Tailscale (names, ssh, remote)
 ┌──────────────┐        ┌───────────────┐        ┌──────────────┐  ┌──────────────┐
 │ head (Ubuntu)│  rpc   │ laptop (Ubuntu│  rpc   │ phone A      │  │ phone B      │
 │ llama-server │◄──────►│ rpc-server    │◄──────►│ rpc-server   │  │ rpc-server   │
 │ k3s server   │        │ k3s agent     │        │ (Termux)     │  │ (Termux)     │
 │ NFS, models  │        │ cluster-agent │        │ cluster-agent│  │ cluster-agent│
 │ clusterd ─── dashboard, join files, heartbeats ──────────────────────────────── │
 └──────────────┘        └───────────────┘        └──────────────┘  └──────────────┘
```

- **One model, many devices.** `llama.cpp` is built with its RPC backend. Each
  worker runs `rpc-server` and offers its memory. `cluster run model.gguf` on the
  head splits the model's layers across every awake device and starts
  `llama-server` with an OpenAI-compatible API. The model only has to fit in
  the *combined* memory.
- **Bigger, not faster.** Every token walks through every device in turn, so
  throughput is bound by the slowest device and link. The planner fills the
  fastest devices first (head GPU, wired GPU, wired CPU) and only reaches for
  Wi‑Fi devices when the model does not fit otherwise.
- **GPUs of any brand, together.** Each device builds `rpc-server` for its own
  GPU (Vulkan for AMD/NVIDIA/Intel, CUDA, ROCm, Adreno OpenCL on Snapdragon
  phones). The head sees them all as generic remote devices.
- **The head owns all state.** Model files, the k3s token, the NFS share, the
  pinned llama.cpp version and the dashboard live on the head. A worker holds a
  config file, a token and two services, so a wiped device rejoins with one
  command.
- **k3s for everything else.** The head is the k3s server, Ubuntu workers are
  agents, so grouped services (anything in a container) can run across them.

## Quick start

**1. Head** (the Ubuntu laptop that stays on):

```bash
git clone https://github.com/sxi9/home-cluster-.git && cd home-cluster-
sudo ./join.sh head              # or: sudo ./head.sh --gpu cuda
```

It prints the two commands below with your head's address filled in, and the
dashboard URL `http://HEAD-IP:8787`.

**2. Each Ubuntu laptop** (the Windows laptop booted into Ubuntu):

```bash
curl -fsSL http://HEAD-IP:8787/worker.sh | sudo bash
```

**3. Each rooted Snapdragon phone**, in Termux (install Termux, Termux:Boot and
optionally Tailscale from F-Droid or the Play Store first):

```bash
pkg install curl && curl -fsSL http://HEAD-IP:8787/android.sh | bash
```

**4. Run a model** on the head:

```bash
cp Qwen2.5-32B-Instruct-Q4_K_M.gguf /srv/cluster/models/
cluster nodes                               # who is awake and what they offer
cluster plan  Qwen2.5-32B-Instruct-Q4_K_M.gguf   # see the split, change nothing
cluster run   Qwen2.5-32B-Instruct-Q4_K_M.gguf   # start it
curl http://HEAD-IP:8080/v1/chat/completions -d '{"messages":[{"role":"user","content":"hi"}]}'
```

No flags are needed anywhere: the served scripts carry the head's address,
workers fetch the token and version pins from the head, and generic hostnames
are replaced with stable ones. Every script has `--dry-run` (prints what it
would do) and `--leave` (undoes it). Settings are saved, so re-running a script
with no arguments after a reboot or wipe just works.

## Dashboard

Served by the head at `http://HEAD-IP:8787`. Live every 2 seconds, no external
dependencies, works offline on the LAN and over Tailscale.

| | |
|---|---|
| ![light](docs/screenshots/dashboard-light.png) | ![table](docs/screenshots/dashboard-table.png) |
| Light theme (follows the OS, toggle on the page) | Table view of every device |

- Per device: role, OS, link (wired / Wi‑Fi), GPU, free RAM and VRAM, what it
  offers to the model, rpc-server state, load, temperature, battery, and the
  layers it holds in the current run. Devices that stop heartbeating fade out.
- Current run: model, context, the layer split as a bar (one colour per
  device), how many layers stayed on the head's CPU, and the bytes llama.cpp
  actually placed on each device.
- Tokens per second for generation and prompt processing, with a two-minute
  sparkline. The numbers come from `llama-server`'s own metrics endpoint.
- Warnings when a phone runs hot or its battery is low and not charging.

<details><summary>Phone-sized view</summary>

![phone](docs/screenshots/dashboard-phone.png)
</details>

## What is in the repo

| file | runs on | purpose |
|---|---|---|
| `join.sh` | any | `join.sh head \| worker \| android`, from a checkout or piped from the head |
| `head.sh` | head | k3s server, NFS export, llama.cpp build, clusterd, join files, pins |
| `worker.sh` | Ubuntu workers | packages, Tailscale, NFS mount, rpc-server build + service, agent, k3s agent |
| `android.sh` | Termux phones | rpc-server build (Adreno OpenCL or CPU), termux-services, boot start, root tweaks |
| `bin/cluster` | head | `nodes`, `plan`, `run`, `status`, `stop`, `logs` |
| `head/clusterd.py` | head | one service: join files, heartbeats, `/api/state`, the dashboard |
| `dashboard/index.html` | head | the dashboard page |
| `agent/cluster-agent.py` | every node | `/metrics` endpoint + heartbeat; standard library only |
| `tests/smoke.sh` | dev | end-to-end test with fake nodes and a fake llama-server; runs in CI |
| `CHECKLIST.md` | you | per-device setup checklist and build progress |
| `docs/` | you | GPU and phone details, troubleshooting |

## GPU support

| device | backend | flag | notes |
|---|---|---|---|
| any AMD / NVIDIA / Intel GPU | Vulkan | `--gpu vulkan` (auto when a GPU is present) | one build for every vendor, no CUDA/ROCm install |
| NVIDIA with CUDA toolkit | CUDA | `--gpu cuda` | fastest on NVIDIA; needs `nvcc` |
| AMD with ROCm | HIP | `--gpu hip` | needs `/opt/rocm`; picky about cards |
| Snapdragon phone | Adreno OpenCL | `--gpu opencl` (auto on Snapdragon) | shares the phone's RAM, adds compute only |
| anything | CPU | `--gpu cpu` | |

A GPU's VRAM is added to the pool and its layers run much faster than on CPU.
Phone GPUs use unified memory, so they do not add capacity. Details and
measured caveats in [docs/gpu-and-phones.md](docs/gpu-and-phones.md).

## Honest status

- Nothing here has been run on real hardware yet. Every script passed
  shellcheck and a full `--dry-run`, and the Python parts pass an end-to-end
  smoke test against fake nodes and a fake `llama-server`. The first real test
  is the two laptops; see [CHECKLIST.md](CHECKLIST.md).
- Phones join the model pool and the dashboard, but not k3s. Stock Android
  kernels lack what k3s needs. `android.sh --chroot` sets up an Ubuntu chroot
  for experiments, nothing more.
- Windows joins by booting into Ubuntu. A native Windows `rpc-server` would work
  for the model pool (not k3s) and is a small addition.
- iOS cannot run any of this without a custom app. See the roadmap.
- The k3s token travels over the home LAN in the clear from the head's join
  service. Keep port 8787 inside the LAN (the scripts add ufw rules for that).

## Roadmap: what else can be added

- **Windows native worker**: `rpc-server` built with CUDA or Vulkan on Windows,
  joining the model pool without a reboot into Ubuntu.
- **iOS / iPadOS**: a small sideloaded app embedding llama.cpp's rpc-server and
  the agent. No root needed, but it needs Xcode and an Apple ID to sideload.
- **Better splitting**: [prima.cpp](https://github.com/OpenCPIL/prima.cpp)
  claims 5 to 17 times lower latency than plain llama.cpp RPC on exactly this
  kind of mixed home cluster, with Android support. Worth a bake-off once the
  cluster runs.
- **A chat UI**: Open WebUI or any OpenAI-compatible client pointed at
  `http://HEAD-IP:8080`, deployed as a k3s service.
- **More in k3s**: Longhorn or NFS-backed volumes, Pi-hole, Home Assistant,
  Immich, media servers, running across the Ubuntu nodes.
- **Wake-on-LAN** from the dashboard for sleeping laptops, and a thermal-aware
  planner that drops a phone when it throttles.
- **Prometheus and Grafana** fed from the agents and llama-server, if you want
  history beyond the dashboard's live view.
