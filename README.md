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
- **Networking**: wired LAN carries per-token model traffic, Wi-Fi is accepted as a slower fallback; Tailscale on every
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

## Quick start (one command per device)

On the head, run `head.sh` once. It prints a join command and serves a small
join directory on the LAN. On every other device, paste that command:

```bash
curl -fsSL http://HEAD-IP:8787/worker.sh | sudo bash
```

That is the whole setup for an Ubuntu worker. With no flags, `worker.sh`:

1. finds the head (the `--join` URL, `cluster-head.local`, or the Tailscale
   name `head`),
2. takes the head address, version pins and k3s token from the join service,
3. names generic hosts `worker-<mac-suffix>`,
4. picks the wired interface, or Wi-Fi if that is all there is,
5. installs and starts everything, and saves its settings for flagless re-runs.

Phones get the same experience through `android.sh` (coming next), which
prepares the Termux chroot and then runs `worker.sh` inside it.

### worker.sh

```bash
sudo ./worker.sh --dry-run                               # preview, changes nothing
sudo ./worker.sh --head 192.168.1.10 --token TOKEN       # fully manual join
sudo ./worker.sh --name laptop2 --rpc-reserve-mb 4096    # override anything
sudo ./worker.sh                                         # re-run after reboot/wipe
sudo ./worker.sh --leave                                 # undo
```

Precedence: flags > values the head publishes > saved `worker.env` > defaults.

Files it leaves on the worker: `/etc/home-cluster/worker.env`,
`/etc/home-cluster/token`, `/etc/systemd/system/rpc-server.service`,
`/opt/llama.cpp/`, an fstab line for `/mnt/cluster`, and the k3s agent.

### Join service contract (what head.sh must serve)

`head.sh` serves `/srv/cluster/join/` over plain HTTP on port 8787, bound to
the LAN interface only. The directory holds:

| file          | content                                                      |
|---------------|--------------------------------------------------------------|
| `worker.sh`   | a copy of this repo's worker.sh, so devices never need git   |
| `cluster.env` | `HEAD=`, `HEAD_SSH=`, `RPC_PORT=`, `LLAMA_REF=`, `K3S_VERSION=` |
| `token`       | the k3s node-token                                           |

The llama.cpp RPC protocol must match on both ends, so workers always build
against the `LLAMA_REF` the head publishes. The token travels over the home
LAN unencrypted; the head should firewall the port to the LAN subnet. The
same `cluster.env` is also mirrored on the NFS share for workers that join
later with the service down.

## Build order

1. `worker.sh` and `head.sh` for Ubuntu, tested on the two laptops.
2. The `rpc-server` systemd service and the `cluster run` command.
3. `android.sh` with the Termux chroot wrapper, tested on one phone.
4. The dashboard.
