# Checklist

Tick these off in order. Each section is independent once the head is up.

## Network

- [ ] Head and laptops on the wired LAN; static DHCP leases set on the router
- [ ] Phones on the same Wi‑Fi (or on USB‑C ethernet adapters, strongly recommended)
- [ ] Tailscale account; the Tailscale app installed on the phones
- [ ] Nothing on the LAN blocks ports 6443, 8787, 8788, 8080, 2049, 50052 between the devices

## Head (Ubuntu laptop)

- [ ] `git clone` the repo, `sudo ./head.sh --dry-run` reads sensibly (interface, GPU, subnet)
- [ ] `sudo ./head.sh --admin-pass '...'` finishes; note the join commands it prints
- [ ] Dashboard asks for a login; `admin` + your password works; Log out works
- [ ] `systemctl status k3s clusterd cluster-agent cluster-mdns nfs-server` all active
- [ ] Dashboard opens at `http://HEAD-IP:8787` and shows the head card
- [ ] `kubectl get nodes` shows the head Ready
- [ ] `ls /srv/cluster/join` has `cluster.env`, `token`, `worker.sh`, `android.sh`, `join.sh`, `cluster-agent.py`
- [ ] A model is in `/srv/cluster/models/`
- [ ] Lid closed does not suspend (head.sh sets this; check `systemctl status sleep.target` is masked)

## Ubuntu worker (the Windows laptop booted into Ubuntu)

- [ ] `curl -fsSL http://HEAD-IP:8787/worker.sh | sudo bash -s -- --dry-run` looks right
- [ ] Real run finishes (the llama.cpp build is the slow part)
- [ ] `systemctl status rpc-server cluster-agent k3s-agent` all active
- [ ] `ss -ltnp | grep 50052` shows rpc-server on the LAN IP only
- [ ] `ls /mnt/cluster` shows the head's share
- [ ] On the head: `cluster nodes` lists it awake with rpc `up`; `kubectl get nodes` shows it Ready
- [ ] Dashboard card shows GPU and VRAM if it has a GPU
- [ ] Reboot the laptop: everything comes back without touching it

## Android phone with the app (root optional)

- [ ] Open `http://HEAD-IP:8787/home-cluster-worker.apk` on the phone, install
- [ ] Enter the head URL, Start; status shows `rpc-server: up` and `head: http://...` with a recent heartbeat
- [ ] Tap "Allow running in background", accept; on Xiaomi/Huawei/OnePlus also lock the app in recents
- [ ] Rooted: status says `root: yes`; grant the su prompt once
- [ ] Snapdragon: status says `backend: Adreno OpenCL`; the dashboard card shows `opencl`; `cluster bench` with Auto and with CPU
- [ ] Mali phone: status says `backend: Vulkan`; the dashboard card shows `vulkan`; `cluster bench` with Auto and with CPU
- [ ] On the head: `cluster nodes` lists the phone with rpc `up`; dashboard card shows `app: android-apk`
- [ ] Screen off for 10 minutes: the phone stays awake on the dashboard
- [ ] Reboot the phone: it comes back within a minute (Start at boot switch)

## Snapdragon phone (Termux)

- [ ] Termux (F-Droid/GitHub build, not the old Play Store one), Termux:Boot, Tailscale installed
- [ ] Opened Termux:Boot once so Android lets it run at boot
- [ ] Battery optimisation disabled for Termux in Android settings (android.sh also does this with root)
- [ ] `pkg install curl && curl -fsSL http://HEAD-IP:8787/android.sh | bash -s -- --dry-run` looks right
- [ ] Real run finishes (10 to 30 minutes for the build; keep the screen on or use a wake lock)
- [ ] `sv status rpc-server cluster-agent` shows both `run`
- [ ] On the head: `cluster nodes` lists the phone awake with rpc `up`, GPU `opencl` on Snapdragon
- [ ] Reboot the phone: `sv status` shows both services back within a minute
- [ ] Decide CPU vs GPU per phone: see docs/gpu-and-phones.md, re-run with `--gpu cpu` if CPU is faster

## Windows PC (native, optional)

- [ ] Elevated PowerShell; paste the `worker.ps1` command head.sh printed
- [ ] `Get-ScheduledTask 'home-cluster*'` shows both tasks Running; `Get-Process rpc-server`
- [ ] On the head: `cluster nodes` lists it awake with rpc `up`
- [ ] If CUDA was chosen, `nvidia-smi` shows rpc-server using the GPU during a run

## Fallback head (optional, second Ubuntu machine)

- [ ] It is already a worker (`cluster nodes` shows it)
- [ ] `curl -fsSL http://HEAD-IP:8787/join.sh | sudo bash -s standby` finishes
- [ ] On the primary: the header pill says `fallback: <name> ready`; `cluster failover status` lists it
- [ ] Test: power off the primary; within a minute `http://STANDBY-IP:8787` shows the FAILOVER banner and the devices; `cluster run` works there
- [ ] Power the primary back on; the standby steps down within a minute and devices return

## First model run

- [ ] `cluster plan MODEL.gguf` shows every awake device and no "does not fit"
- [ ] `cluster run MODEL.gguf` reaches `running`
- [ ] Dashboard shows the layer split and a tokens/sec number while a request runs
- [ ] `curl http://HEAD-IP:8080/v1/chat/completions ...` answers
- [ ] Try `--exclude phone-x` and `--wifi` to see how the split and speed change
- [ ] `cluster bench` once; the dashboard shows a speed per device and a 🐢 on the slowest
- [ ] `cluster tune KV_CACHE_TYPE=q8_0` then `cluster plan` shows the flag; try `FLASH_ATTN=on` on GPU devices
- [ ] `cluster top` shows every device's processes; alerts appear on the dashboard for hogs
- [ ] `cluster run big.gguf --draft small.gguf` and compare tokens/sec on the dashboard
- [ ] `cluster ui`, open http://HEAD-IP:30080, create the admin account, chat
- [ ] `cluster exec --all -- uptime` reaches every Ubuntu and Termux device
- [ ] `cluster share`, open the dashboard from a phone on mobile data via Tailscale

## Build progress

- [x] worker.sh for Ubuntu
- [x] head.sh for Ubuntu
- [x] rpc-server systemd service (in worker.sh)
- [x] `cluster run` with planner, `nodes`, `plan`, `status`, `stop`, `logs`
- [x] android.sh with Termux services and Adreno OpenCL
- [x] join.sh dispatcher and one-command joins served by the head
- [x] Dashboard with screenshots
- [x] GPU backends: Vulkan, CUDA, ROCm, Adreno OpenCL
- [x] Smoke test + CI
- [ ] Tested on the two laptops
- [ ] Tested on one phone
- [ ] Ubuntu chroot on a phone (experimental, `android.sh --chroot`)
- [x] Windows native worker (worker.ps1, untested)
- [x] Speculative decoding, Open WebUI, one-controller `cluster exec`, `cluster share`
- [x] `cluster bench` / `cluster tune` / `cluster top` / `cluster kill`, hardware details, network diagram
- [x] Real RPC split verified in the cloud with llama.cpp master (see README)
- [x] Dashboard login, `cluster tune --auto`, standby head with automatic failover (untested on hardware)
- [x] Android app (root and non-root) with rpc-server inside; APK built, not yet installed on a phone
- [x] Android app: Adreno OpenCL build (second binary in the APK, auto-selected, CPU fallback)
- [x] Android app: Vulkan build for Mali phones, auto-selected with fallback chain
- [x] Android app run in an emulator: rpc-server up, heartbeats reach the head, dashboard shows the phone
- [ ] Android app: measured on a Snapdragon phone, GPU vs CPU with `cluster bench`
- [ ] Android app: measured on a Mali phone (Exynos/Tensor/MediaTek), Vulkan vs CPU
- [ ] Tested worker.ps1 on the Windows laptop
- [ ] iOS worker app
