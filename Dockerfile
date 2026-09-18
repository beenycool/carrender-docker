# syntax=docker/dockerfile:1
#
# carrender - headless Blender render container for the wet-night motorway shot.
#
# Targets x86-64 GPU hosts (SaladCloud, Vast, bare metal).  Build it with
# --platform linux/amd64 even from an arm64 machine - Salad GPUs are x86-64.
#
#   docker buildx build --platform linux/amd64 -f docker/Dockerfile -t <user>/carrender:5.2.1 --push .
#   docker run --rm --gpus all -v $PWD:/data <user>/carrender:5.2.1 render
#
# Blender bundles its own Cycles CUDA/OptiX kernels AND its own CUDA runtime, so
# the image needs NO CUDA toolkit - only the DRIVER, which the NVIDIA Container
# Toolkit injects at run time.  A plain ubuntu base is therefore used: it is
# smaller (faster Salad cold start) and it dodges the broken apt keyring the
# nvidia/cuda images ship (apt-get update there fails with
# NO_PUBKEY 871920D1991BC93C / "unsupported filetype" on trusted.gpg.d).
#
# If a host ever fails to inject libcuda/libnvoptix, rebuild with
#   --build-arg BASE_IMAGE=nvidia/cuda:12.8.1-runtime-ubuntu22.04
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ARG BLENDER_VERSION=5.2.1
ARG BLENDER_SHA256="a31f524fa99a527d3d52b7f5aaa68c34e1a19d5a1c9473f79c5cc610fd5b10e9"
ENV BLENDER_VER=${BLENDER_VERSION}

ENV DEBIAN_FRONTEND=noninteractive \
    BLENDER_USER_CONFIG=/tmp/blender-config \
    BLENDER_USER_SCRIPTS=/tmp/blender-scripts \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Blender links these even in `-b` mode; ffmpeg does the H.264 encode.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils ffmpeg tar gzip coreutils \
        rclone \
        libx11-6 libxi6 libxxf86vm1 libxfixes3 libxrender1 libxrandr2 \
        libxinerama1 libxcursor1 libxkbcommon0 libxext6 \
        libgl1 libglu1-mesa libegl1 libsm6 libice6 \
        libgomp1 libsndfile1 libopenal1 libfontconfig1 libfreetype6 \
        libdbus-1-3 libasound2 libtbb2 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/blender.tar.xz \
        "https://download.blender.org/release/Blender${BLENDER_VERSION%.*}/blender-${BLENDER_VERSION}-linux-x64.tar.xz" \
    && echo "downloaded $(stat -c %s /tmp/blender.tar.xz) bytes" \
    && echo "${BLENDER_SHA256}  /tmp/blender.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/blender \
    && tar -xJf /tmp/blender.tar.xz -C /opt/blender --strip-components=1 \
    && rm /tmp/blender.tar.xz \
    && ln -sf /opt/blender/blender /usr/local/bin/blender \
    && blender -b --version | head -3

COPY preflight.py render.py entrypoint.sh /opt/carrender/
RUN chmod +x /opt/carrender/entrypoint.sh

WORKDIR /data
# Salad batch groups: the container runs, writes, uploads, exits 0.
ENTRYPOINT ["/opt/carrender/entrypoint.sh"]
CMD ["render"]
