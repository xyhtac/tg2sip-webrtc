
# =============================================================================
# tg2sip-webrtc — standalone service image
#
# Initial implementation: single-stage build.
#
# Why a single stage?
#   The application links against a large set of native libraries, including
#   libraries pulled in by ntgcalls' prebuilt WebRTC archive. Keeping the build
#   dependencies installed avoids prematurely removing a runtime dependency.
#   Once the image works, we can use ldd and runtime tests to make a smaller
#   multi-stage image.
#
# IMPORTANT:
#   Build from the repository root after initializing the ntgcalls submodule:
#     git submodule update --init --recursive
#
#   This image does NOT configure your SIP peer, credentials, or deployment
#   networking. Those are supplied by your runtime configuration.
# =============================================================================

FROM ubuntu:24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# -----------------------------------------------------------------------------
# 1. Establish predictable build paths.
#
# CMakePresets.json and build-clang-libcxx-deps.sh currently agree on a prefix
# under $HOME/claudetmp/toolchain-libcxx-install.
#
# Preserve that existing convention here rather than silently changing the
# checked-in preset. A later cleanup can replace this with a configurable
# TG2SIP_DEPS_PREFIX variable.
# -----------------------------------------------------------------------------

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/opt/buildhome

ENV PREFIX=/opt/buildhome/claudetmp/toolchain-libcxx-install
ENV PKG_CONFIG_PATH=/opt/buildhome/claudetmp/toolchain-libcxx-install/lib/pkgconfig:/opt/buildhome/claudetmp/toolchain-libcxx-install/lib/x86_64-linux-gnu/pkgconfig
ENV LD_LIBRARY_PATH=/opt/buildhome/claudetmp/toolchain-libcxx-install/lib:/opt/buildhome/claudetmp/toolchain-libcxx-install/lib/x86_64-linux-gnu

WORKDIR /app

# -----------------------------------------------------------------------------
# 2. Install the compiler, build tools, and native development dependencies.
#
# CMakeLists.txt requires CMake >= 3.27 because of ntgcalls. Ubuntu 24.04
# provides a newer CMake than the 3.18 release used by the legacy Dockerfiles.
#
# The X11, XCB, Mesa, VA-API, VDPAU, GLib, Boost, FFmpeg, and OpenH264
# development packages cover native dependencies referenced by the current
# CMake configuration and ntgcalls integration.
#
# Keep these development packages in this first working image. Removing them
# before verifying the final runtime dependency closure can break startup.
# -----------------------------------------------------------------------------

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        clang \
        libc++-dev \
        libc++abi-dev \
        cmake \
        ninja-build \
        pkg-config \
        git \
        ca-certificates \
        curl \
        wget \
        sudo \
        python3 \
        perl \
        nasm \
        yasm \
        patchelf \
        gperf \
        ccache \
        zlib1g-dev \
        libssl-dev \
        libopus-dev \
        libavcodec-dev \
        libavformat-dev \
        libavutil-dev \
        libswscale-dev \
        libswresample-dev \
        libglib2.0-dev \
        libpcre2-dev \
        libffi-dev \
        libboost-all-dev \
        libgbm-dev \
        libdrm-dev \
        libvdpau-dev \
        libva-dev \
        libopenh264-dev \
        libx11-dev \
        libx11-xcb-dev \
        libxcb1-dev \
        libxcb-composite0-dev \
        libxcb-damage0-dev \
        libxcb-xfixes0-dev \
        libxcb-randr0-dev \
        libxau-dev \
        libxcomposite-dev \
        libxdamage-dev \
        libxext-dev \
        libxfixes-dev \
        libxrandr-dev \
        libxrender-dev \
        libxtst-dev \
        clang-18 \
        libclang-rt-18-dev \
        clang-20 \
        libclang-rt-20-dev \
    && rm -rf /var/lib/apt/lists/*

# Fail early if the base image's compiler or CMake doesn't meet the
# requirements. This makes build-environment failures obvious in CI logs.
RUN cmake --version \
    && clang++ --version \
    && test "$(cmake --version | head -n1 | awk '{print $3}' | cut -d. -f1)" -ge 3

# -----------------------------------------------------------------------------
# 3. Pin the dependency source checkouts.
#
# TDLib v1.8.38 is a reasonable starting point: the project's own CMake
# comments explicitly identify it as a supported newer version.
#
# PJSIP_REF is configurable because the current dependency script does not
# specify which PJSIP revision its original checkout used. The default below
# is a proposed starting point, not a version verified against your existing
# working build. Override it if your tested checkout uses another revision.
# -----------------------------------------------------------------------------

ARG TDLIB_REF=v1.8.38
ARG PJSIP_REF=2.14.1

RUN mkdir -p "${HOME}/claudetmp" \
    && git clone --depth 1 \
        https://github.com/tdlib/td.git \
        "${HOME}/claudetmp/td" \
    && git clone --depth 1 --branch "${PJSIP_REF}" \
        https://github.com/pjsip/pjproject.git \
        "${HOME}/claudetmp/pjproject-clang"

# The PJSIP build script expects the project's custom config_site.h.
COPY buildenv/config_site.h /tmp/config_site.h

RUN cp /tmp/config_site.h \
        "${HOME}/claudetmp/pjproject-clang/pjlib/include/pj/config_site.h"

# -----------------------------------------------------------------------------
# 4. Build the C++ dependencies using the repository's existing script.
#
# This builds TDLib, PJSIP, spdlog, and Abseil with Clang/libc++, installing
# them into the prefix expected by CMakePresets.json.
#
# The script uses sudo for certain operations. sudo is installed above, and
# this initial image builds as root.
#
# The script's default TD_SRC and PJPROJECT_SRC paths intentionally match the
# checkout locations created in the previous step.
# -----------------------------------------------------------------------------

COPY buildenv/build-clang-libcxx-deps.sh /tmp/build-clang-libcxx-deps.sh

RUN chmod +x /tmp/build-clang-libcxx-deps.sh \
    && PREFIX="${PREFIX}" \
       TD_SRC="${HOME}/claudetmp/td" \
       PJPROJECT_SRC="${HOME}/claudetmp/pjproject-clang" \
       SPDLOG_SRC="${HOME}/claudetmp/spdlog" \
       ABSEIL_SRC="${HOME}/claudetmp/abseil-cpp" \
       bash /tmp/build-clang-libcxx-deps.sh

# Verify the expected PJSIP pkg-config metadata exists before configuring
# the main application. This also helps catch an incorrect installation
# prefix early.
RUN test -f "${PREFIX}/lib/pkgconfig/libpjproject.pc" \
    || test -f "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/libpjproject.pc"

# -----------------------------------------------------------------------------
# 5. Copy the application source tree.
#
# Build the image from a checkout with third_party/ntgcalls initialized.
# The application CMake configuration applies project-specific patches and
# modifies the downloaded WebRTC archive, so the source tree must be writable.
#
# Ensure .dockerignore does not exclude third_party/ntgcalls or the project's
# patches and buildenv scripts.
# -----------------------------------------------------------------------------

COPY . /app


RUN set -eux; \
    pwd; \
    ls -l third_party/ntgcalls/CMakeLists.txt; \
    ls -l patches/0001-tg2sip-ntgcalls-add_subdirectory-fixes.patch; \
    ls -l buildenv/rename-webrtc-openssl-symbols.sh; \
    ls -l buildenv/rename-webrtc-libsrtp-symbols.sh; \
    test -f third_party/ntgcalls/CMakeLists.txt; \
    test -f patches/0001-tg2sip-ntgcalls-add_subdirectory-fixes.patch; \
    test -x buildenv/rename-webrtc-openssl-symbols.sh; \
    test -x buildenv/rename-webrtc-libsrtp-symbols.sh    

# -----------------------------------------------------------------------------
# 6. Configure and compile the actual application.
#
# The preset uses the same $HOME/claudetmp/toolchain-libcxx-install prefix
# populated by the dependency build above.
#
# CMake also downloads/configures ntgcalls' prebuilt WebRTC dependencies and
# applies the project's OpenSSL/libsrtp symbol-renaming steps.
#
# Build both executable targets:
#   build-clang/tg2sip-webrtc
#   build-clang/tg2sip-gendb
#
# JOBS is configurable so builds can be constrained on smaller CI runners.
# -----------------------------------------------------------------------------

ARG JOBS=4

RUN cmake --preset clang-libcxx \
    && cmake --build build-clang --parallel "${JOBS}" \
    && test -x build-clang/tg2sip-webrtc \
    && test -x build-clang/tg2sip-gendb \
    && test -f build-clang/tg2sip.conf.sample

# -----------------------------------------------------------------------------
# 7. Runtime defaults.
#
# Keep the working directory alongside the generated sample configuration.
# Mount your own tg2sip.conf into this directory at container startup.
#
# No ports are declared here because the correct SIP/RTP ports and transport
# settings depend on your configuration. Configure Docker networking and
# firewall rules to match the actual application settings.
# -----------------------------------------------------------------------------

WORKDIR /app/build-clang

# Run the gateway in the foreground so Docker can supervise its process and
# collect stdout/stderr. Override CMD to run the database utility if needed.
CMD ["./tg2sip-webrtc"]
