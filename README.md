# carrender-docker

Headless **Blender 5.2.1** render container for a Cycles/GPU shot, built to survive
**ephemeral GPU hosts like SaladCloud** — where there is no persistent disk, the
machine can be preempted mid-render, and the container is thrown away afterwards.

It renders a `.blend` to numbered PNGs, encodes them to H.264, and can push both
the intermediate state and the final video out over plain HTTP (pre-signed URLs —
no cloud SDKs, no credentials baked into the image).

- Cycles **GPU (CUDA/OptiX)** with the **OptiX GPU denoiser**
- **Resumable**: finished frames are skipped, so a crash or preemption restarts
  where it left off
- **Preemption-safe**: frames are tarred and `PUT` to a `STATE_URL` every N frames
  and pulled back at startup
- **No GPU required to build**; ~680 MB image, no CUDA toolkit (Blender ships its
  own kernels and runtime — only the driver is injected at run time)

---

## Quick start (any GPU host)

```bash
docker build --platform linux/amd64 -t carrender:5.2.1 .
docker run --rm --gpus all -v "$PWD:/data" carrender:5.2.1 render
```

`find_scene()` picks up the largest `.blend` under `/data`. Frames land in
`/data/frames`, the video in `/data/out/carrender.mp4`.

Check the GPU and denoiser first — this is the one thing worth verifying before a
long run:

```bash
docker run --rm --gpus all -v "$PWD:/data" carrender:5.2.1 preflight
```

```
gpu        : NVIDIA GeForce RTX 3090, 550.xx, 24576 MiB
device     : OPTIX  ['NVIDIA GeForce RTX 3090']
device=OPTIX denoiser=OPTIX
```

If it prints `denoiser=OIDN`, the host is missing the OptiX denoiser weights. The
render still works but the CPU denoiser becomes the bottleneck — on a 2-vCPU box
it is 39 s/frame versus ~1.5 s for the whole frame with OptiX.

---

## SaladCloud

1. **Push the image** (CI does this — see below) or build and push it yourself:
   ```bash
   docker buildx build --platform linux/amd64 \
     -t ghcr.io/<you>/carrender-docker:5.2.1 --push .
   ```
2. Create a **Container Group** of type **Batch** (it runs to completion and exits).
3. Image: `ghcr.io/<you>/carrender-docker:5.2.1`
4. Set the environment below. Salad has **no persistent volume**, so if you skip
   `SCENE_URL` the container has nothing to render, and if you skip `UPLOAD_URL`
   the render is lost when the container exits.

### Required on Salad

| Variable | Purpose |
|---|---|
| `SCENE_URL` | Pre-signed **GET** URL for your `.blend`. Downloaded to `/data/scene/scene.blend`. |
| `SCENE_SHA256` | Optional integrity check for the above. |
| `STATE_URL` | Pre-signed **PUT** URL for `frames.tar`. Pushed every `CHUNK` frames, pulled back at startup. **This is what makes preemption survivable.** |
| `STATE_URL_GET` | Pre-signed **GET** for the same object. Defaults to `STATE_URL` if the URL accepts both verbs. |
| `UPLOAD_URL` | Pre-signed **PUT** URL for the final `carrender.mp4`. |

Any S3-compatible bucket works (AWS S3, Cloudflare R2, Backblaze B2, MinIO).
Generate one pre-signed URL per object with a long expiry — the render can take
tens of minutes.

Alternatively bake the scene into the image (no `SCENE_URL` needed) by adding to
the `Dockerfile`:

```dockerfile
COPY your_scene.blend /opt/carrender/scene.blend
```

### Optional

| Variable | Default | Purpose |
|---|---|---|
| `COMMAND` (args) | `render` | `render` \| `preflight` \| `encode` \| `bench` \| `shell` |
| `RES_PCT` | `50` | `resolution_percentage`. 50 → 1080×1920 for a 2160×3840 scene |
| `SAMPLES` | `32` | `cycles.samples` |
| `BOUNCES` | `6` | `cycles.max_bounces` |
| `TEXLIMIT` | `2048` | `cycles.texture_limit_render`; `OFF` for a 4K master on ≥16 GB |
| `DEVICE` | `OPTIX` | `OPTIX` \| `CUDA` \| `CPU` |
| `DENOISER` | `auto` | `auto` \| `OPTIX` \| `OIDN` \| `NONE` |
| `PERSIST` | `1` | `use_persistent_data` — builds the BVH once per process |
| `STEP` | `1` | Render every Nth frame |
| `FRAMES` | – | Explicit comma list, e.g. `1,40,120` |
| `CHUNK` | `32` | Frames per pass before a state upload |
| `FPS` | `24` | Encode frame rate (divided by `STEP` automatically) |
| `CRF` | `16` | x264 quality (lower = better) |
| `ENCODE` | `1` | Set `0` to render PNGs only |
| `RETRIES` | `3` | Retries for a failed render pass |
| `UPLOAD_CMD` | – | Arbitrary post-render hook, e.g. `rclone copy /data/out remote:out` |

---

## Which GPU

Because Salad's pricing tracks performance almost linearly, the **total cost of a
pass barely changes across the stack** (roughly $0.02 for a 192-frame 1080p pass).
So choose on **VRAM** and **denoiser support**, not on speed:

| GPU | $/hr | VRAM | Why |
|---|---|---|---|
| **RTX 3090** | **0.143** | 24 GB | **Best pick.** Renders a 4K master with full textures (the scene peaks ~9.8 GB) and has headroom for the OptiX denoiser. |
| RTX 3060 | 0.067 | 12 GB | Cheapest that does the job at 1080p. Tight but workable at 4K with `TEXLIMIT=2048`. |
| RTX 4090 | 0.273 | 24 GB | Same VRAM as the 3090, ~1.8× faster, ~2× the price. |
| RTX 5090 | 0.417 | 32 GB | Fastest by a wide margin. ~3× the 3090's price for ~2.5× the speed — convenience, not value. |
| RTX 3060 Ti / 2080 Ti | 0.063 / 0.087 | 8 / 11 GB | Fine at 1080p, **not** for a 4K master. |
| **Any AMD** | – | – | **Avoid.** No OptiX, and Cycles' HIP path is much slower — the CPU denoiser will dominate. |

**VRAM is the first filter.** At 2160×3840 the scene peaks around 9.8 GB with full
textures, so an 8 GB card will only manage 4K with `TEXLIMIT=2048` and little
denoiser headroom. 12 GB is the safe floor; 16 GB+ is comfortable.

Rough single-pass times (192 frames, 1080×1920, 32 spp, OptiX denoise), scaled from
a measured 7.6 s/frame on an RTX 3060 Laptop:

| 3060 12 GB | 3090 | 4090 | 5090 |
|---|---|---|---|
| ~17 min | ~8 min | ~5 min | ~3 min |

Setup, image pull and the scene download usually cost more wall-clock than the
render itself, so do not optimize the GPU choice too hard.

---

## Build & publish (GitHub Actions)

`.github/workflows/docker-image.yml` builds `linux/amd64` and pushes to GHCR on
every push to `main` and on version tags. No secrets to configure — it uses the
built-in `GITHUB_TOKEN`.

The published package is **private by default**. Salad then needs registry
credentials, or make the package public:

```bash
gh api -X PATCH /user/packages/container/carrender-docker \
  -f visibility=public
```

(Or GitHub → your profile → Packages → the package → Package settings → Change
visibility.) The image contains no scene and no credentials, so a public package
is normally fine.

Building on an **arm64** machine requires `--platform linux/amd64` and QEMU; CI is
easier, and it is what the workflow is for.

---

## How the resumability works

```
fetch scene ──▶ restore frames.tar ──▶ preflight (device/denoiser)
                                            │
                    ┌───────────────────────┘
                    ▼
        render CHUNK frames ──▶ tar frames ──▶ PUT STATE_URL
                    │                              │
                    └── more frames? ──────────────┘   (loop)
                    │
                    ▼
        ffmpeg encode ──▶ PUT UPLOAD_URL
```

Every pass re-invokes `blender -b scene.blend -P render.py`, which renders only
the frames whose PNG is not already on disk. `LIMIT` bounds one pass so the state
tar is never more than `CHUNK` frames out of date. A `SIGTERM` (Salad preemption)
is trapped: whatever exists is pushed before exiting, and the next container
resumes from it.

---

## Test

No GPU and no Blender needed — the smoke test runs the real entrypoint against a
stub Blender and asserts the chunking, resume, encode and upload behaviour:

```bash
tests/smoke.sh
```

It builds `Dockerfile.smoke`, runs a 5-frame job in chunks of 2 over a local
HTTP server that accepts `PUT`, then runs a second container to prove it resumes
instead of re-rendering. Expect `14 passed, 0 failed`.

---

## Verified / not verified

- ✅ Image builds for `linux/amd64` (683 MB) and `blender -b --version` reports
  `Blender 5.2.1 LTS`
- ✅ 14/14 smoke tests pass (chunk, state push/pull, resume, encode, upload)
- ⚠️ **Not verified on a real GPU.** The Cycles/OptiX path has not been executed
  end-to-end on CUDA hardware. Run `preflight` on the target host before a long
  render — that is what it is for.
- ⚠️ The base is `ubuntu:22.04`, not an `nvidia/cuda` image, because Blender needs
  no CUDA toolkit and the `nvidia/cuda` images ship a broken apt keyring. If a host
  ever fails to inject `libcuda`/`libnvoptix`, rebuild with
  `--build-arg BASE_IMAGE=nvidia/cuda:12.8.1-runtime-ubuntu22.04`.
