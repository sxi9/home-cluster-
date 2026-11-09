#!/usr/bin/env bash
# Build llama.cpp's rpc-server for Android arm64 with the NDK and drop it into the
# app as librpc-server.so (the name lets Android extract and execute it).
#   ANDROID_NDK=/path/to/ndk ./build-rpc-server.sh [LLAMA_REF]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REF=${1:-master}
NDK=${ANDROID_NDK:-${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}}
[[ -d $NDK ]] || { echo "set ANDROID_NDK to the NDK directory" >&2; exit 1; }
SRC=${LLAMA_SRC:-$HERE/.llama.cpp}
if [[ ! -d $SRC/.git ]]; then git clone --quiet https://github.com/ggml-org/llama.cpp "$SRC"; fi
git -C "$SRC" fetch --quiet --tags origin
git -C "$SRC" checkout --quiet --force "$REF"
[[ $REF == master ]] && git -C "$SRC" pull --quiet --ff-only
rm -rf "$SRC/build-android"
cmake -S "$SRC" -B "$SRC/build-android" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_RPC=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=OFF \
  -DCMAKE_C_FLAGS="-march=armv8.2-a+fp16+dotprod" -DCMAKE_CXX_FLAGS="-march=armv8.2-a+fp16+dotprod"
target=rpc-server
cmake --build "$SRC/build-android" --target help | grep -q ggml-rpc-server && target=ggml-rpc-server
cmake --build "$SRC/build-android" --target "$target" -j "$(nproc)"
mkdir -p "$HERE/app/src/main/jniLibs/arm64-v8a" "$HERE/app/src/main/assets"
cp -f "$SRC/build-android/bin/$target" "$HERE/app/src/main/jniLibs/arm64-v8a/librpc-server.so"
for strip in "$NDK"/toolchains/llvm/prebuilt/*/bin/llvm-strip; do
  [[ -x $strip ]] && "$strip" "$HERE/app/src/main/jniLibs/arm64-v8a/librpc-server.so" && break
done
git -C "$SRC" rev-parse HEAD > "$HERE/app/src/main/assets/llama_ref.txt"
ls -la "$HERE/app/src/main/jniLibs/arm64-v8a/librpc-server.so"
echo "built rpc-server from llama.cpp $(cat "$HERE/app/src/main/assets/llama_ref.txt")"
