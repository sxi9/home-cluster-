#!/usr/bin/env bash
# Build llama.cpp's rpc-server for Android arm64 with the NDK, twice:
#   librpc-server.so     CPU backend, runs on any arm64 phone
#   librpc-server-cl.so  OpenCL backend with the Adreno kernels, for Snapdragon phones
#   librpc-server-vk.so  Vulkan backend, for Mali (Exynos, Tensor, MediaTek) and other GPUs
# All land in app/src/main/jniLibs/arm64-v8a (the name lets Android extract + execute them).
#   ANDROID_NDK=/path/to/ndk ./build-rpc-server.sh [LLAMA_REF] [cpu|opencl|vulkan|all]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REF=${1:-master}
WHAT=${2:-all}
NDK=${ANDROID_NDK:-${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}}
[[ -d $NDK ]] || { echo "set ANDROID_NDK to the NDK directory" >&2; exit 1; }
SRC=${LLAMA_SRC:-$HERE/.llama.cpp}
DEPS=${CL_DEPS:-$HERE/.opencl}
OUT=$HERE/app/src/main/jniLibs/arm64-v8a
TOOLCHAIN=$NDK/build/cmake/android.toolchain.cmake
mkdir -p "$OUT" "$HERE/app/src/main/assets"

if [[ ! -d $SRC/.git ]]; then git clone --quiet https://github.com/ggml-org/llama.cpp "$SRC"; fi
git -C "$SRC" fetch --quiet --tags origin
git -C "$SRC" checkout --quiet --force "$REF"
[[ $REF == master ]] && git -C "$SRC" pull --quiet --ff-only
git -C "$SRC" rev-parse HEAD > "$HERE/app/src/main/assets/llama_ref.txt"

strip_bin() {
  local strip
  for strip in "$NDK"/toolchains/llvm/prebuilt/*/bin/llvm-strip; do
    [[ -x $strip ]] && "$strip" "$1" && break
  done
  return 0
}

common=(-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_RPC=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF
        -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=OFF
        -DCMAKE_C_FLAGS="-march=armv8.2-a+fp16+dotprod" -DCMAKE_CXX_FLAGS="-march=armv8.2-a+fp16+dotprod")

build_one() {   # build_one <builddir> <output name> [extra cmake flags...]
  local bdir=$1 name=$2; shift 2
  rm -rf "$bdir"
  cmake -S "$SRC" -B "$bdir" -G Ninja "${common[@]}" "$@"
  local target=rpc-server    # ggml-rpc-server on current llama.cpp, rpc-server on older tags
  grep -qs 'ggml-rpc-server' "$SRC/tools/rpc/CMakeLists.txt" && target=ggml-rpc-server
  cmake --build "$bdir" --target "$target" -j "$(nproc)"
  cp -f "$bdir/bin/$target" "$OUT/$name"
  strip_bin "$OUT/$name"
  ls -la "$OUT/$name"
}

if [[ $WHAT == cpu || $WHAT == all ]]; then
  echo "== CPU backend"
  build_one "$SRC/build-android" librpc-server.so
fi

if [[ $WHAT == opencl || $WHAT == all ]]; then
  echo "== OpenCL backend (Adreno kernels embedded)"
  # Khronos headers + ICD loader, built with the NDK, kept out of the NDK tree.
  # At runtime the phone's own /vendor/lib64/libOpenCL.so (the real driver) is loaded instead.
  mkdir -p "$DEPS"
  [[ -d $DEPS/OpenCL-Headers/.git ]] || git clone --quiet --depth 1 https://github.com/KhronosGroup/OpenCL-Headers "$DEPS/OpenCL-Headers"
  [[ -d $DEPS/OpenCL-ICD-Loader/.git ]] || git clone --quiet --depth 1 https://github.com/KhronosGroup/OpenCL-ICD-Loader "$DEPS/OpenCL-ICD-Loader"
  if [[ ! -s $DEPS/lib/libOpenCL.so ]]; then
    cmake -S "$DEPS/OpenCL-ICD-Loader" -B "$DEPS/build-icd" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_shared \
      -DOPENCL_ICD_LOADER_HEADERS_DIR="$DEPS/OpenCL-Headers" -DOPENCL_ICD_LOADER_BUILD_TESTING=OFF
    cmake --build "$DEPS/build-icd" -j "$(nproc)"
    mkdir -p "$DEPS/lib"; cp -f "$DEPS/build-icd/libOpenCL.so" "$DEPS/lib/libOpenCL.so"
  fi
  build_one "$SRC/build-android-cl" librpc-server-cl.so \
    -DGGML_OPENCL=ON -DGGML_OPENCL_EMBED_KERNELS=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=ON \
    -DOpenCL_INCLUDE_DIR="$DEPS/OpenCL-Headers" -DOpenCL_LIBRARY="$DEPS/lib/libOpenCL.so"
fi
if [[ $WHAT == vulkan || $WHAT == all ]]; then
  echo "== Vulkan backend (Mali and others)"
  # The NDK ships the Vulkan headers, libvulkan.so and glslc; the shader generator is a host
  # tool that ggml builds with the host compiler while cross-compiling.
  SYSROOT=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot
  GLSLC=$(find "$NDK/shader-tools" -name glslc -type f | head -n1)
  # ggml-vulkan wants the SPIRV-Headers CMake package (header-only); install it under $DEPS
  mkdir -p "$DEPS"
  [[ -d $DEPS/SPIRV-Headers/.git ]] || git clone --quiet --depth 1 https://github.com/KhronosGroup/SPIRV-Headers "$DEPS/SPIRV-Headers"
  if [[ ! -d $DEPS/spirv/share/cmake/SPIRV-Headers ]]; then
    cmake -S "$DEPS/SPIRV-Headers" -B "$DEPS/build-spirv" -DCMAKE_INSTALL_PREFIX="$DEPS/spirv" >/dev/null
    cmake --install "$DEPS/build-spirv" >/dev/null
  fi
  # ggml-vulkan is written against Vulkan-Hpp (vulkan/vulkan.hpp), which the NDK does not ship
  [[ -d $DEPS/Vulkan-Headers/.git ]] || git clone --quiet --depth 1 https://github.com/KhronosGroup/Vulkan-Headers "$DEPS/Vulkan-Headers"
  # Android 10 (API 29) is the first libvulkan stub that exports the Vulkan 1.1 entry points
  # ggml-vulkan links against (vkGetPhysicalDeviceFeatures2); the app skips this binary below 29.
  build_one "$SRC/build-android-vk" librpc-server-vk.so \
    -DANDROID_PLATFORM=android-29 \
    -DGGML_VULKAN=ON -DCMAKE_PREFIX_PATH="$DEPS/spirv" -DSPIRV-Headers_DIR="$DEPS/spirv/share/cmake/SPIRV-Headers" \
    -DVulkan_INCLUDE_DIR="$DEPS/Vulkan-Headers/include" \
    -DCMAKE_CXX_FLAGS="-march=armv8.2-a+fp16+dotprod -I$DEPS/spirv/include" \
    -DVulkan_LIBRARY="$SYSROOT/usr/lib/aarch64-linux-android/29/libvulkan.so" \
    -DVulkan_GLSLC_EXECUTABLE="$GLSLC"
fi
echo "built from llama.cpp $(cat "$HERE/app/src/main/assets/llama_ref.txt")"
