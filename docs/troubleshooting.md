# Troubleshooting

**A worker is "asleep" on the dashboard but the device is on.**
Its agent is not heartbeating. On the device: `systemctl status cluster-agent`
(Ubuntu) or `sv status cluster-agent` (Termux), then
`curl -s http://DEVICE-IP:8788/metrics`. The agent posts to the `JOIN_URL` in
its `worker.env`; check that the head's address there is still right.

**rpc is "down" for a device.**
`rpc-server` is bound to the LAN IP saved in `worker.env`. If the device got a
new address, re-run `worker.sh` (it rewrites the file and restarts the
service). On Termux the service re-reads the address at every restart:
`sv restart rpc-server`.

**`cluster run` says the model does not fit.**
`cluster plan MODEL.gguf` shows what each device offers. Options: wake more
devices, allow Wi‑Fi devices with `--wifi`, lower `--ctx`, lower `--margin`,
or pick a smaller quantisation. Layers that fit nowhere go to the head's CPU
RAM, which is why the head needs free memory too.

**llama-server fails to load with an RPC error or a protocol mismatch.**
Every device must run the same llama.cpp commit. The head pins it in
`/srv/cluster/join/cluster.env`; workers build that commit. After updating the
head (`head.sh` again), re-run `worker.sh` / `android.sh` on every device.

**The build fails on a device.**
Check `--gpu`. Vulkan needs `glslc`; CUDA needs the toolkit; HIP needs ROCm.
Fall back with `--gpu cpu` to confirm the rest works, then fix the backend.

**Phones drop out mid-generation.**
Usually the low-memory killer or thermal throttling. Lower the phone's offer
with `--rpc-reserve-mb 3072`, keep it on a charger and a cool surface, make
sure Termux is excluded from battery optimisation, and prefer a USB‑C ethernet
adapter over Wi‑Fi.

**k3s agent never becomes Ready.**
`journalctl -u k3s-agent -f` on the worker. Common causes: the token changed
(re-run `worker.sh`, it re-fetches), the head's port 6443 is firewalled, or
the k3s versions differ (the head pins it; `worker.sh` follows the pin).

**The join command works on laptops but not on a phone.**
Phones cannot resolve `cluster-head.local`. The scripts the head serves carry
its IP, so always use the command `head.sh` printed (with the IP), or pass
`--head IP`.

**Generation is slow.**
Expected: every token crosses every device. Check `cluster plan`: a Wi‑Fi
phone holding many layers caps the speed. Use `--exclude phone-x` or let the
planner leave it out by making the model fit on the wired devices.
