# GPUs and phones

## Mixing GPU vendors

Each `rpc-server` is built against one backend and exposes that device to the
head. The head's `llama-server` only sees a list of remote devices, so a CUDA
laptop, a Vulkan laptop and an OpenCL phone can serve one model together.
`cluster run` lists them with `--device` in a fixed order and splits layers
with `--tensor-split`, so the layer ranges shown on the dashboard match what
llama.cpp does.

What each backend needs on the device:

| backend | packages installed by the scripts | you install first |
|---|---|---|
| Vulkan | `libvulkan-dev glslc mesa-vulkan-drivers vulkan-tools` | the normal GPU driver (Mesa for AMD/Intel, the NVIDIA driver) |
| CUDA | nothing extra | CUDA toolkit (`nvcc` on PATH or in `/usr/local/cuda`) |
| HIP (ROCm) | nothing extra | ROCm in `/opt/rocm`; the script picks the first `gfx` target from `rocminfo` |
| Adreno OpenCL (Termux) | `opencl-headers opencl-clhpp ocl-icd opencl-vendor-driver` | nothing; uses `/vendor/lib64/libOpenCL.so` |

Change the backend any time with `--gpu ...`; the build is redone only when
the backend or the pinned llama.cpp commit changes.

The `rpc-server` service user is added to the `video` and `render` groups so
it can open the GPU device nodes.

## Memory accounting

- A GPU worker offers its free VRAM (reported by the backend). The planner
  keeps `--margin` percent (default 12) of it free for compute buffers.
- A CPU worker offers `min(free RAM, total RAM − reserve)`; the reserve is
  `--rpc-reserve-mb` (2048 on laptops and phones by default).
- Phones and laptop iGPUs use unified memory. Their GPU adds compute, not
  capacity, so the planner counts the phone's RAM once.
- The KV cache is estimated from the model's head count and the context size
  and spread over the layers. Bigger `--ctx` means fewer layers per device.

## Snapdragon phones

- The Adreno OpenCL backend in llama.cpp targets Snapdragon 8 Gen 1 and newer
  (Adreno 7xx and 8xx). Older Adreno 6xx works but gains little.
- Published results are mixed: Qualcomm's own numbers favour the GPU, while a
  community Termux benchmark on a Snapdragon 778G and 8 Gen 2 found the CPU
  faster for token generation. Measure on your phone:

  ```bash
  # on the phone, after android.sh; needs a small model on the phone
  $PREFIX/opt/llama.cpp/src/build/bin/llama-bench -m small.gguf -ngl 0     # CPU
  $PREFIX/opt/llama.cpp/src/build/bin/llama-bench -m small.gguf -ngl 99    # GPU
  ```

  (`llama-bench` is not built by default; build it with
  `cmake --build $PREFIX/opt/llama.cpp/src/build --target llama-bench`.)
  Re-run `android.sh --gpu cpu` if the CPU wins. The phone's main contribution
  is RAM either way.
- Q4_0 quantisations are the fast path for Adreno kernels. Q4_K_M works but is
  slower on the GPU.
- Thermal throttling starts within a minute or two of sustained load. The
  dashboard flags phones above 75 °C and 85 °C. A fan or a cold surface helps
  more than any flag.
- Wi‑Fi is the bottleneck for phones. A USB‑C to ethernet adapter (any cheap
  one) makes a phone a far better worker; android.sh prefers `eth0` when it
  has an address.
- Android's low-memory killer will target a process holding gigabytes. With
  root, android.sh sets `oom_score_adj` to −1000 for rpc-server, whitelists
  Termux from battery optimisation and keeps Wi‑Fi on during sleep. Without
  root the phone still works, with a higher chance of the model dropping out.
- Termux:Boot runs `~/.termux/boot/01-home-cluster.sh` at boot, which takes a
  wake lock and starts the termux-services supervisor; `rpc-server` and
  `cluster-agent` are enabled services under it.

## Ubuntu chroot on a phone

`android.sh --chroot` downloads the Ubuntu 24.04 arm64 base image into
`/data/local/ubuntu` and installs an `ubuntu-chroot` command that mounts
`/proc`, `/sys`, `/dev` and `/sdcard` and drops you into it. It is there for
grouped services you want in a real Ubuntu userland. k3s is not started inside
it: stock Android kernels lack cgroup v2 and netfilter modules it requires. If
your kernel has them, `worker.sh --no-build --no-tailscale --no-lid-ignore`
inside the chroot is the place to try.
