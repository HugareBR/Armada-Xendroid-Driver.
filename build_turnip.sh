#!/bin/bash -e
set -o pipefail

deps="git ninja patchelf unzip curl flex bison zip glslangValidator python3 ccache pkg-config"

workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"

mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"
srcfolder="mesa"

BUILD_VERSION="${BUILD_VERSION:-${GITHUB_RUN_NUMBER:-local}}"

check_deps() {
    echo "== Checking dependencies =="

    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "ERROR: Missing dependency: $dep"
            exit 1
        fi
    done

    python3 -m pip install \
        --break-system-packages \
        -U meson mako packaging pyyaml
}

prepare_workdir() {
    echo "== Preparing workdir =="

    rm -rf "$workdir"
    mkdir -p "$workdir"
    cd "$workdir"

    echo "== Downloading Android NDK $ndkver =="

    curl -fL \
        "https://dl.google.com/android/repository/${ndkver}-linux.zip" \
        -o "${ndkver}-linux.zip"

    unzip -q "${ndkver}-linux.zip"

    echo "== Cloning Mesa =="

    git clone \
        --depth=1 \
        --branch main \
        "$mesasrc" \
        "$srcfolder"
}

build_lib_for_android() {
    cd "$workdir/$srcfolder"

    echo "== Mesa commit =="
    git log -1 --oneline

    # Android compatibility fixes
    sed -i 's/ (%s)//g' \
        src/freedreno/vulkan/tu_device.cc 2>/dev/null || true

    sed -i 's/ (%s)//g' \
        src/freedreno/vulkan/tu_device.c 2>/dev/null || true

    sed -i \
        's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' \
        include/android_stub/cutils/native_handle.h 2>/dev/null || true

    sed -i \
        's/, hnd->handle/, (void *)hnd->handle/g' \
        src/util/u_gralloc/u_gralloc_fallback.c 2>/dev/null || true

    sed -i \
        's/native_buffer->handle->/((const native_handle_t *)native_buffer->handle)->/g' \
        src/vulkan/runtime/vk_android.c 2>/dev/null || true

    sed -i \
        's/anb->handle->/((const native_handle_t *)anb->handle)->/g' \
        src/vulkan/runtime/vk_android.c 2>/dev/null || true

    export PATH="$ndk:$PATH"

    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export RANLIB=llvm-ranlib
    export STRIP=llvm-strip
    export OBJDUMP=llvm-objdump
    export OBJCOPY=llvm-objcopy
    export LDFLAGS="-fuse-ld=lld"

    GITHASH="$(git rev-parse --short HEAD)"

    # Highest API available in NDK r29
    cver="36"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="35"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="34"

    echo "== Android API $cver =="

    cat > android-aarch64.txt <<EOF
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android${cver}-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android${cver}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=/nonexistent', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cat > native.txt <<EOF
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

    echo "== Configuring Turnip Android ARM64 MSM =="

    meson setup build-android-aarch64 \
        --cross-file android-aarch64.txt \
        --native-file native.txt \
        --prefix /tmp/turnip-msm \
        -Dbuildtype=release \
        -Dstrip=true \
        -Dplatforms=android \
        -Dvideo-codecs= \
        -Dplatform-sdk-version="$cver" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=msm \
        -Dallow-fallback-for=libdrm \
        -Degl=disabled \
        -Dandroid-libbacktrace=disabled

    echo "== Building =="

    ninja -C build-android-aarch64 install

    DRIVER="/tmp/turnip-msm/lib/libvulkan_freedreno.so"

    if [ ! -s "$DRIVER" ]; then
        echo "ERROR: libvulkan_freedreno.so was not generated."
        exit 1
    fi

    echo "== Driver generated =="
    ls -lh "$DRIVER"
    sha256sum "$DRIVER"

    cd /tmp/turnip-msm/lib

    cat > meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "StevenMXZ A6xx/A7xx MSM ${BUILD_VERSION}",
  "description": "Mesa Turnip Android ARM64 adapted for Armada OS / Waydroid MSM DRM",
  "author": "StevenMXZ fork / Armada MSM build",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Mesa-${GITHASH}-MSM",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    ZIP="/tmp/turnip-msm-V${BUILD_VERSION}.zip"

    echo "== Packaging =="

    zip -9 "$ZIP" \
        libvulkan_freedreno.so \
        meta.json

    cp "$ZIP" "$workdir/"

    echo "== Finished =="

    ls -lh "$workdir"/*.zip
    unzip -l "$workdir/$(basename "$ZIP")"
}

check_deps
prepare_workdir
build_lib_for_android
