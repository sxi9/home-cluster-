# Android app (root and non-root)

`android-app/` is a small Kotlin app that turns any arm64 Android phone into a
worker without Termux. It ships llama.cpp's `rpc-server` inside the APK and
runs it as a foreground service, with the same agent the other devices run.

| | non-root phone | rooted phone |
|---|---|---|
| joins the model pool (`rpc-server`) | yes | yes |
| shows on the dashboard (agent, heartbeat, fallback heads) | yes | yes |
| survives screen off | yes: foreground service + wake lock + Wi‑Fi lock | yes |
| survives memory pressure | mostly: ask for the battery exemption in the app | yes: `oom_score_adj -1000` on rpc-server |
| starts at boot | yes (switch in the app) | yes |
| Wi‑Fi stays on in sleep | depends on the phone's settings | forced on |
| GPU: Adreno OpenCL | yes, when the phone has `/vendor/lib64/libOpenCL.so` (Snapdragon) | yes |
| GPU: Vulkan (Mali on Exynos/Tensor/MediaTek, others) | yes, when Android advertises Vulkan hardware support | yes |
| k3s | no | no |

## Install

1. On the head, after `head.sh`: the APK is served at
   `http://HEAD-IP:8787/home-cluster-worker.apk` when a build is in `releases/`
   or dropped into `/srv/cluster/`. Open that address in the phone's browser,
   install (allow "unknown sources" for the browser once).
2. Open the app, enter the head URL `http://HEAD-IP:8787`, optionally a name
   and the RAM to keep for Android (2048 MB default), tap **Start**.
3. Tap **Allow running in background** and accept; on Xiaomi/Huawei/OnePlus
   also lock the app in the recents screen and disable their own battery
   killers (see docs/troubleshooting.md).
4. On the head: `cluster nodes` lists the phone; the dashboard card shows
   `app: android-apk`.

## GPU backends

The APK carries three `rpc-server` binaries: CPU, OpenCL (Adreno-tuned
kernels embedded) and Vulkan. The **GPU backend** choice in the app is
`Auto` by default: OpenCL when the phone has a vendor OpenCL driver
(`/vendor/lib64/libOpenCL.so`, present on Snapdragon phones), otherwise
Vulkan when Android reports Vulkan hardware support (Mali GPUs in Exynos,
Tensor and MediaTek phones, and most others), otherwise CPU. Each backend
gets two attempts; if it keeps dying at start the app moves to the next one
in the chain and says so on the status screen. You can also pin a backend.

The Vulkan binary uses Android's own `/system/lib64/libvulkan.so`, a public
library, so no loader tricks are needed. Mali support in llama.cpp's Vulkan
backend is newer and less tuned than Adreno OpenCL: expect it to work on
Mali-G7x and newer, and to be slower than the CPU on some phones. Measure
with `cluster bench`. For the OpenCL binary: The driver sits outside the app's linker namespace, so
the binary is launched with `LD_LIBRARY_PATH` pointing at the vendor
libraries, and compiled kernels are cached in the app's cache directory so
later starts are fast. If the OpenCL binary dies twice within its first 15
seconds (unsupported GPU, odd driver), the app falls back to the CPU binary
for that session and says so on its status screen and in the log.

`rpc-server` picks the first non-CPU device by default, so with the OpenCL
build the Adreno GPU is what serves. The dashboard shows `opencl · Adreno
(...)` on the phone's card. Memory is unified on phones: the GPU adds compute,
not capacity, and whether it beats the CPU for generation varies by chipset;
`cluster bench` measures it over RPC, then switch the toggle and bench again.

Supported per llama.cpp's docs: Adreno 750 (8 Gen 3), 810 (7s Gen 3), 830 (8
Elite), 840. Older Adreno 6xx/7xx usually run but gain little.

## Build

GitHub Actions builds it on every push that touches `android-app/`
(`.github/workflows/android.yml`) and attaches `home-cluster-worker.apk` as an
artifact. Run the workflow by hand with a `llama_ref` input to match the commit
the head pinned. Locally:

```bash
ANDROID_NDK=/path/to/ndk android-app/build-rpc-server.sh b12098 all   # CPU, OpenCL and Vulkan rpc-server binaries
cd android-app && gradle assembleDebug                              # app/build/outputs/apk/debug/app-debug.apk
```

The build in this repo's `releases/` was made from llama.cpp `b12098` and
contains all three binaries (CPU 1.6 MB, OpenCL 5.5 MB, Vulkan 22 MB with its
SPIR-V shaders embedded; 15 MB as an APK). The head must run the same commit
(`head.sh --llama-ref b12098`) or the RPC protocol may not match. The Vulkan
binary needs Android 10 or newer; the app skips it on older phones.

## How it works

- `rpc-server` is packaged as `lib/arm64-v8a/librpc-server.so`. Android only
  lets an app execute binaries from its native library directory, and only if
  they are extracted (`useLegacyPackaging`), so that is where it lives.
- `WorkerService` is a foreground service (`dataSync` type) with a persistent
  notification and a Stop action. It restarts `rpc-server` if it exits.
- `Agent` answers `/metrics`, `/processes` (empty: Android hides other apps'
  processes) and `/sink` on port 8788, and heartbeats to the head every 10 s,
  switching to standby heads from the heartbeat reply when the primary is down.
- `Root` runs `su` once to check, then whitelists the app from doze, allows
  background running and protects the `rpc-server` pid from the low-memory
  killer. Without `su` nothing is attempted.
- The debug keystore signs the APK; updates must come from the same signer,
  which CI provides consistently. For Play-store style signing, add a release
  keystore to the workflow.

## Limits

- Vulkan on phones depends on the OEM's driver quality; a crash at start is
  caught by the fallback chain, a crash mid-run restarts `rpc-server` (the
  current model run on the head will have to be started again).
- No process list for other apps (Android 8+ hides it); the dashboard shows
  memory, CPU, temperature, battery and storage instead.
- Phones cannot resolve `cluster-head.local`; always use the head's IP.
