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
| GPU (Adreno OpenCL) | no, CPU only in this build | no, use `android.sh` (Termux) for the GPU path |
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

## Build

GitHub Actions builds it on every push that touches `android-app/`
(`.github/workflows/android.yml`) and attaches `home-cluster-worker.apk` as an
artifact. Run the workflow by hand with a `llama_ref` input to match the commit
the head pinned. Locally:

```bash
ANDROID_NDK=/path/to/ndk android-app/build-rpc-server.sh b12098   # rpc-server → librpc-server.so
cd android-app && gradle assembleDebug                              # app/build/outputs/apk/debug/app-debug.apk
```

The build in this repo's `releases/` was made from llama.cpp `b12098`; the
head must run the same commit (`head.sh --llama-ref b12098`) or the RPC
protocol may not match.

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

- CPU only. The Adreno OpenCL build needs the OpenCL headers and ICD loader
  compiled for Android inside the NDK build; that is the next step for this
  app. Phone GPUs add compute, not memory, so the pool size is the same.
- No process list for other apps (Android 8+ hides it); the dashboard shows
  memory, CPU, temperature, battery and storage instead.
- Phones cannot resolve `cluster-head.local`; always use the head's IP.
