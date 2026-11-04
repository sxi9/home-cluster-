# home-cluster

A home compute cluster that pools the RAM of a few devices so one large
language model can run across all of them, with k3s for grouped services.

| device            | role   | how                          |
|-------------------|--------|------------------------------|
| Ubuntu laptop     | head   | runs natively                |
| Windows laptop    | worker | booted into Ubuntu           |
| Android phone A/B | worker | Ubuntu in a Termux chroot    |

## Design

- **Head owns all shared state**: model files, the k3s join token, an NFS
  export at `/srv/cluster`. Workers hold only a token and a service unit, so a
  wiped device rejoins in minutes.
- **Networking**: wired LAN carries per-token model traffic; Tailscale on every
  device for stable names, SSH and off-home access. Static DHCP leases.
- **Orchestration**: k3s, head as server, every worker as an agent.
- **Model splitting**: llama.cpp built with `GGML_RPC=ON`. `rpc-server` on each
  worker offers its RAM; the head splits the model by layers across them. This
  makes bigger models possible, not faster.
- **Resilience**: `rpc-server` is a systemd service on each worker.

## Scripts

| file          | status  | purpose                                                   |
|---------------|---------|-----------------------------------------------------------|
| `worker.sh`   | written | join an Ubuntu machine as a worker (`--dry-run` to preview) |
| `head.sh`     | next    | set up the head: k3s server, NFS export, pinned versions  |
| `cluster`     | planned | `cluster run model.gguf`: poll workers, build `--rpc` list |
| `android.sh`  | planned | Termux chroot wrapper around `worker.sh`                  |
| `join.sh`     | planned | `./join.sh head | worker | android`                       |
| dashboard     | planned | nodes, free RAM, layers held, tokens/sec                  |

### worker.sh

```bash
sudo ./worker.sh --dry-run --head 192.168.1.10          # preview, changes nothing
sudo ./worker.sh --head 192.168.1.10 --name laptop2     # first join (token: flag, env, ssh, or prompt)
sudo ./worker.sh                                        # re-run after reboot/wipe, settings are saved
sudo ./worker.sh --leave                                # undo
```

Files it leaves on the worker: `/etc/home-cluster/worker.env`,
`/etc/home-cluster/token`, `/etc/systemd/system/rpc-server.service`,
`/opt/llama.cpp/`, an fstab line for `/mnt/cluster`, and the k3s agent.

If the head publishes `/srv/cluster/cluster.env` with `LLAMA_REF=` and
`K3S_VERSION=`, workers build against those pins. The llama.cpp RPC protocol
must match on both ends, so head.sh will write that file.

## Build order

1. `worker.sh` and `head.sh` for Ubuntu, tested on the two laptops.
2. The `rpc-server` systemd service and the `cluster run` command.
3. `android.sh` with the Termux chroot wrapper, tested on one phone.
4. The dashboard.
