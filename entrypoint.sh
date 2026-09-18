#!/usr/bin/env bash
# carrender entrypoint - built for ephemeral GPU hosts (SaladCloud batch groups).
#
#   docker run --rm --gpus all carrender:5.2.1 render
#
# Salad has no persistent volume, so this container is designed around that:
#   * the scene is DOWNLOADED at start (SCENE_URL) or baked into the image
#   * finished frames are tarred and PUSHED OUT every SYNC_EVERY frames, and the
#     tar is pulled back at start, so a preempted run resumes instead of restarting
#   * the final mp4 is uploaded with a pre-signed PUT (UPLOAD_URL), no cloud SDKs
#
# Commands: render (default) | preflight | encode | bench | shell
set -euo pipefail

SCENE="${SCENE:-}"
SCENE_URL="${SCENE_URL:-}"
SCENE_SHA256="${SCENE_SHA256:-}"
SCENE_DIR="${SCENE_DIR:-/data/scene}"
FRAMES_DIR="${FRAMES_DIR:-/data/frames}"
OUT="${OUT:-/data/out}"

RES_PCT="${RES_PCT:-50}"        # 50 -> 1080x1920 for this 2160x3840 scene
SAMPLES="${SAMPLES:-32}"
BOUNCES="${BOUNCES:-6}"
TEXLIMIT="${TEXLIMIT:-2048}"
DEVICE="${DEVICE:-OPTIX}"
DENOISER="${DENOISER:-auto}"    # auto | OPTIX | OIDN | NONE
PERSIST="${PERSIST:-1}"
STEP="${STEP:-1}"
TAG="${TAG:-}"
FPS="${FPS:-24}"
CRF="${CRF:-16}"
ENCODE="${ENCODE:-1}"
RETRIES="${RETRIES:-3}"
FRAMES="${FRAMES:-}"

# resumability across preemption / restarts
CHUNK="${CHUNK:-32}"            # frames per render pass before a state upload
SYNC_EVERY="${SYNC_EVERY:-$CHUNK}"
STATE_URL="${STATE_URL:-}"      # pre-signed PUT for frames.tar
STATE_URL_GET="${STATE_URL_GET:-${STATE_URL}}"   # pre-signed GET (defaults to same)
UPLOAD_URL="${UPLOAD_URL:-}"    # pre-signed PUT for the encoded mp4
UPLOAD_CMD="${UPLOAD_CMD:-}"    # arbitrary post-render hook (rclone/aws/cp/...)

log()  { printf '\033[1;36m[carrender]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[carrender]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[carrender]\033[0m %s\n' "$*" >&2; exit 1; }
sha()  { sha256sum "$1" | cut -d' ' -f1; }

on_term() {
  warn "signal caught - uploading what exists, then exiting"
  sync_out || true
  exit 143
}
trap on_term TERM INT

# --------------------------------------------------------------- scene
fetch_scene() {
  mkdir -p "$SCENE_DIR" "$FRAMES_DIR" "$OUT"
  if [ -n "$SCENE_URL" ]; then
    if [ -n "$SCENE" ] && [ -f "$SCENE" ]; then
      log "scene already present: $SCENE"
    else
      log "downloading scene: ${SCENE_URL%%\?*}"
      curl -fSL --retry 3 --retry-delay 2 -o "$SCENE_DIR/scene.blend" "$SCENE_URL" \
        || die "scene download failed"
      SCENE="$SCENE_DIR/scene.blend"
      if [ -n "$SCENE_SHA256" ]; then
        log "scene sha256 $(sha "$SCENE") (expect $SCENE_SHA256)"
        [ "$(sha "$SCENE")" = "$SCENE_SHA256" ] || die "scene sha256 mismatch"
      fi
    fi
  fi
  if [ -z "$SCENE" ] || [ ! -f "$SCENE" ]; then
    if [ -f /opt/carrender/scene.blend ]; then
      SCENE=/opt/carrender/scene.blend
    else
      SCENE="$(find /data /opt/carrender -maxdepth 3 -name '*.blend' \
                -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
    fi
  fi
  [ -n "$SCENE" ] && [ -f "$SCENE" ] \
    || die "no scene: set SCENE_URL= (pre-signed GET) or bake one in, or mount one at /data"
  log "scene: $SCENE ($(du -h "$SCENE" | cut -f1))"
}

# --------------------------------------------------- incremental state (tar)
sync_out() {
  [ -n "$STATE_URL" ] || return 0
  local n
  n="$(find "$FRAMES_DIR" -name 'f*.png' 2>/dev/null | wc -l)"
  [ "$n" -gt 0 ] || return 0
  tar -C "$FRAMES_DIR" -czf /tmp/frames.tar.gz .
  log "state: pushing $n frames ($(du -h /tmp/frames.tar.gz | cut -f1))"
  curl -fsS --retry 3 -X PUT --upload-file /tmp/frames.tar.gz \
       -H 'Content-Type: application/gzip' "$STATE_URL" \
    && log "state: pushed" || warn "state push failed (continuing)"
}

restore_out() {
  [ -n "$STATE_URL_GET" ] || return 0
  log "state: trying to resume from $STATE_URL_GET"
  if curl -fsS --retry 2 -o /tmp/frames_in.tar.gz "$STATE_URL_GET"; then
    mkdir -p "$FRAMES_DIR"
    tar -C "$FRAMES_DIR" -xzf /tmp/frames_in.tar.gz \
      && log "state: restored $(find "$FRAMES_DIR" -name 'f*.png' | wc -l) frames" \
      || warn "state: tar was not readable, starting fresh"
  else
    log "state: nothing to resume (first run)"
  fi
}

# ------------------------------------------------------------- preflight
preflight() {
  log "gpu: $(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || echo 'NO GPU VISIBLE')"
  local out
  set +e
  out="$(blender -b "$SCENE" -P /opt/carrender/preflight.py 2>&1)"
  set -e
  echo "$out" | grep -vE '^(Fra:|Blender quit|Saved:|Info: )' || true

  local pf_device pf_den
  pf_device="$(echo "$out" | sed -n 's/^PREFLIGHT_DEVICE=//p' | tail -1)"
  pf_den="$(echo "$out" | sed -n 's/^PREFLIGHT_DENOISER=//p' | tail -1)"
  pf_device="${pf_device:-CPU}"; pf_den="${pf_den:-NONE}"

  # The Colab failure mode: the enum accepts OPTIX but the render then dies with
  # "Unable to load denoiser weights".  Fall back to OIDN and say so loudly.
  if [ "$pf_den" = "OPTIX" ] && echo "$out" | grep -qiE 'unable to load denoiser|denoiser weights'; then
    warn "OptiX denoiser weights missing on this host -> OIDN (CPU)"
    warn "OIDN needs vCPUs: 39 of 48 s/frame on a 2-vCPU box in the project notes"
    pf_den="OIDN"
  fi
  log "device=$pf_device denoiser=$pf_den"
  printf '%s' "$pf_device" > /tmp/pf_device
  printf '%s' "$pf_den"    > /tmp/pf_denoiser
}
resolve_device()   { [ -f /tmp/pf_device ]   && cat /tmp/pf_device   || echo "$DEVICE"; }
resolve_denoiser() { [ "$DENOISER" != auto ] && { echo "$DENOISER"; return; }
                     [ -f /tmp/pf_denoiser ] && cat /tmp/pf_denoiser || echo OPTIX; }

# ---------------------------------------------------------------- render
render_pass() {
  RES_PCT="$RES_PCT" SAMPLES="$SAMPLES" BOUNCES="$BOUNCES" TEXLIMIT="$TEXLIMIT" \
  OUTDIR="$FRAMES_DIR" DEVICE="$1" DENOISER="$2" STEP="$STEP" TAG="$TAG" \
  FRAMES="$FRAMES" LIMIT="$3" PERSIST="$PERSIST" \
    blender -b "$SCENE" -P /opt/carrender/render.py
}

do_render() {
  local dev den attempt=0
  dev="$(resolve_device)"; den="$(resolve_denoiser)"
  log "render ${RES_PCT}% / ${SAMPLES} spp / ${BOUNCES} bounces / ${dev} + ${den} denoise"
  mkdir -p "$FRAMES_DIR"

  # an explicit frame list is a one-shot pass; otherwise render in chunks so the
  # state tar is pushed periodically and a preemption does not lose the run
  local chunk="$CHUNK"
  if [ -n "$FRAMES" ]; then chunk=0; fi

  while :; do
    attempt=$((attempt + 1))
    local logf rc
    logf="$(mktemp)"
    set +e
    render_pass "$dev" "$den" "$chunk" 2>&1 | tee "$logf"
    rc="${PIPESTATUS[0]}"
    set -e

    if [ $rc -eq 0 ]; then
      case "$(cat "$logf")" in
        *"RENDER DONE"*|*"nothing to do"*) sync_out; rm -f "$logf"; break ;;
        *"CHUNK DONE"*)                    sync_out; rm -f "$logf"; continue ;;
        *) sync_out; rm -f "$logf"; break ;;
      esac
    fi
    if [ "$attempt" -ge "$RETRIES" ]; then
      sync_out || true
      die "render failed $attempt times (last rc=$rc) - frames rendered so far were pushed"
    fi
    warn "render attempt $attempt exited $rc - retrying (finished frames are kept)"
    sleep 5
  done
}

# ---------------------------------------------------------------- encode
do_encode() {
  [ "$ENCODE" = "1" ] || { log "ENCODE=0, skipping"; return 0; }
  local suf="" pattern count enc_fps
  [ -n "$TAG" ] && suf="_$TAG"
  pattern="$FRAMES_DIR/f%04d$suf.png"
  count="$(find "$FRAMES_DIR" -name "f*$suf.png" | wc -l)"
  [ "$count" -gt 0 ] || { warn "no frames matching $pattern - nothing to encode"; return 0; }
  enc_fps="$FPS"
  if [ "$STEP" != "1" ]; then
    enc_fps="$(awk -v f="$FPS" -v s="$STEP" 'BEGIN{printf "%.6g", f/s}')"
    warn "STEP=$STEP: encoding $count frames at $enc_fps fps so playback is real-time"
  fi
  mkdir -p "$OUT"
  log "encoding $count frames -> $OUT/carrender.mp4 (${enc_fps} fps, crf $CRF)"
  ffmpeg -hide_banner -loglevel warning -y \
    -framerate "$enc_fps" -start_number 1 -i "$pattern" \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
    -c:v libx264 -preset slow -crf "$CRF" -pix_fmt yuv420p \
    -movflags +faststart "$OUT/carrender.mp4"
  log "wrote $OUT/carrender.mp4 ($(du -h "$OUT/carrender.mp4" | cut -f1)) sha256 $(sha "$OUT/carrender.mp4")"
}

upload() {
  [ -n "$UPLOAD_URL" ] || return 0
  local f="$OUT/carrender.mp4"
  [ -f "$f" ] || { warn "UPLOAD_URL set but $f does not exist"; return 0; }
  log "uploading $(du -h "$f" | cut -f1) -> ${UPLOAD_URL%%\?*}"
  curl -fsS --retry 3 -X PUT --upload-file "$f" \
       -H 'Content-Type: video/mp4' "$UPLOAD_URL" \
    && log "uploaded carrender.mp4" || warn "upload failed"
}

# ------------------------------------------------------------------ main
cmd="${1:-render}"
case "$cmd" in
  preflight) fetch_scene; preflight ;;
  render)
    fetch_scene
    restore_out
    preflight
    do_render
    do_encode
    if [ -n "$UPLOAD_CMD" ]; then log "UPLOAD_CMD: $UPLOAD_CMD"; eval "$UPLOAD_CMD" || warn "UPLOAD_CMD failed"; fi
    upload
    log "ALL DONE"
    ;;
  bench)
    fetch_scene
    preflight
    F0="$(blender -b "$SCENE" --python-expr \
          'import bpy;print("CAR_F0",bpy.context.scene.frame_start)' 2>/dev/null \
          | sed -n 's/^CAR_F0 //p' | tail -1)"
    F0="${F0:-1}"
    FRAMES="$F0,$((F0 + 1)),$((F0 + 2)),$((F0 + 3))"
    TAG="bench"; ENCODE=0
    log "bench frames: $FRAMES (first frame includes the BVH build)"
    do_render
    ;;
  encode) fetch_scene; do_encode; upload ;;
  shell) exec /bin/bash ;;
  *) die "unknown command '$cmd' (render|preflight|encode|bench|shell)" ;;
esac
