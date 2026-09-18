#!/usr/bin/env bash
# carrender entrypoint - built for ephemeral GPU hosts (SaladCloud batch groups).
#
#   docker run --rm --gpus all carrender:5.2.1 render
#
# Salad has no persistent volume, so the container is designed around that.  Two
# interchangeable ways to get data in and out - use whichever you already have:
#
#   A) rclone remote   (e.g. Google Drive / S3 / B2 / R2)
#        RCLONE_CONFIG_B64 + RCLONE_REMOTE
#        scene  <- <remote>/scene/scene.blend
#        frames <-> <remote>/frames          (incremental, per file)
#        video  -> <remote>/out/carrender.mp4
#
#   B) pre-signed URLs (any HTTP storage, no SDK, no credentials in the image)
#        SCENE_URL (GET), STATE_URL (PUT frames.tar), UPLOAD_URL (PUT mp4)
#
# A is usually less work; B puts no long-lived credential in the container.
#
# Commands: render (default) | preflight | encode | bench | shell
set -euo pipefail

SCENE="${SCENE:-}"
SCENE_URL="${SCENE_URL:-}"
SCENE_SHA256="${SCENE_SHA256:-}"
SCENE_DIR="${SCENE_DIR:-/data/scene}"
FRAMES_DIR="${FRAMES_DIR:-/data/frames}"
OUT="${OUT:-/data/out}"

RES_PCT="${RES_PCT:-50}"        # 50 -> 1080x1920 for a 2160x3840 scene
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
CHUNK="${CHUNK:-32}"            # frames per render pass before a state sync
STATE_URL="${STATE_URL:-}"      # pre-signed PUT for frames.tar
STATE_URL_GET="${STATE_URL_GET:-${STATE_URL}}"
UPLOAD_URL="${UPLOAD_URL:-}"
UPLOAD_CMD="${UPLOAD_CMD:-}"

# rclone remote (option A)
RCLONE_REMOTE="${RCLONE_REMOTE:-}"        # e.g. gdrive:carrender
RCLONE_CONFIG_B64="${RCLONE_CONFIG_B64:-}"
RCLONE_CONFIG_B64_2="${RCLONE_CONFIG_B64_2:-}"   # second half, if the field truncates
RCLONE_CONFIG="${RCLONE_CONFIG:-}"        # raw config text, if you cannot paste base64
RCLONE_CONF="/tmp/rclone.conf"
# Timeouts are not optional here.  rclone's default I/O timeout is 5 MINUTES, so a
# stalled connection to Drive looks exactly like a hang; and Drive rate-limits
# small chunks hard, which makes rclone restart a 146 MB upload from zero.  Big
# chunks + fast timeouts turn both failure modes into a quick retry.
RCLONE_FLAGS=(--config "$RCLONE_CONF" --stats-one-line --stats 20s --transfers 4 \
              --timeout 60s --contimeout 15s --low-level-retries 10 --retries 3 \
              --drive-chunk-size 32M --tpslimit 8)

log()  { printf '\033[1;36m[carrender]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[carrender]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[carrender]\033[0m %s\n' "$*" >&2; exit 1; }
sha()  { sha256sum "$1" | cut -d' ' -f1; }
rc()   { rclone "${RCLONE_FLAGS[@]}" "$@"; }

on_term() {
  warn "signal caught - syncing what exists, then exiting"
  sync_out || true
  exit 143
}
trap on_term TERM INT


# Decoding a pasted secret is the fragile part: env-var fields wrap, quote, trim
# padding or add a trailing newline.  Accept all of that rather than dying, so the
# operator gets a real error instead of "invalid base64".
write_config() {
  local raw="$1" s
  s="$(printf '%s' "$raw" | tr -d ' \t\r\n')"
  s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"     # strip surrounding quotes
  case "$s" in data:*) s="${s#data:}"; s="${s#*base64,}" ;; esac
  if printf '%s' "$s" | grep -qE '^[A-Za-z0-9+/]+={0,2}$'; then
    case $(( ${#s} % 4 )) in                                # restore stripped padding
      2) s="${s}==" ;;
      3) s="${s}=" ;;
      1) die "config is not valid base64: length ${#s}, starts '${s:0:12}', ends '${s: -12}'" ;;
    esac
    printf '%s' "$s" | base64 -d > "$RCLONE_CONF" 2>/dev/null \
      || die "RCLONE_CONFIG_B64 decoded to nothing useful (length ${#s})"
    # a real config is text with [sections]; garbage decodes to binary
    grep -q '^\[' "$RCLONE_CONF" || {
      if printf '%s' "$raw" | grep -q '^\['; then
        warn "RCLONE_CONFIG_B64 did not decode to a config; using it raw"
        printf '%s\n' "$raw" > "$RCLONE_CONF"
      else
        die "RCLONE_CONFIG_B64 decoded, but the result has no [section] - wrong value?"
      fi
    }
  elif printf '%s' "$raw" | grep -q '^\['; then
    warn "RCLONE_CONFIG_B64 looks like a raw config, not base64 - using it as-is"
    printf '%s\n' "$raw" > "$RCLONE_CONF"
  else
    die "config is neither base64 nor a raw rclone config: length ${#raw}, starts '${raw:0:12}', ends '${raw: -12}'"
  fi
  log "rclone config: $(wc -l < "$RCLONE_CONF") lines, $(wc -c < "$RCLONE_CONF") bytes, sections: $(grep -c '^\[' "$RCLONE_CONF")"
}

# --------------------------------------------------------------- rclone
setup_rclone() {
  [ -n "$RCLONE_REMOTE" ] || return 0
  command -v rclone >/dev/null 2>&1 || die "RCLONE_REMOTE is set but rclone is not in the image"
  if [ -n "$RCLONE_CONFIG_B64" ]; then
    # a long secret gets truncated in a web env field, so allow up to 4 parts
    cfg_all="$RCLONE_CONFIG_B64"
    for n in 2 3 4; do
      var="RCLONE_CONFIG_B64_$n"
      v="${!var:-}"
      [ -n "$v" ] && { cfg_all+="$v"; log "config: + \$$var (${#v} chars)"; }
    done
    log "config: total ${#cfg_all} chars"
    write_config "$cfg_all"
    chmod 600 "$RCLONE_CONF"
  elif [ -n "$RCLONE_CONFIG" ]; then
    printf '%s\n' "$RCLONE_CONFIG" > "$RCLONE_CONF"
    chmod 600 "$RCLONE_CONF"
  elif [ ! -f "$RCLONE_CONF" ]; then
    die "RCLONE_REMOTE is set but there is no RCLONE_CONFIG_B64/RCLONE_CONFIG and no $RCLONE_CONF"
  fi
  grep -q '^\[' "$RCLONE_CONF" \
    || die "$RCLONE_CONF has no [section] - the config did not survive the paste"
  local rname="${RCLONE_REMOTE%%:*}"
  local got
  got="$(rclone --config "$RCLONE_CONF" listremotes 2>/dev/null | tr -d '\r')"
  [ -n "$got" ] || die "$RCLONE_CONF lists no remotes - the pasted config is incomplete"
  # catches a truncated paste that still begins with '[section]'
  printf '%s\n' "$got" | grep -qx "${rname}:" \
    || die "RCLONE_REMOTE is '$RCLONE_REMOTE' but the config only defines: $(printf '%s' "$got" | tr '\n' ' ')"
  log "remotes: $(printf '%s' "$got" | tr '\n' ' ')  |  target: $RCLONE_REMOTE"
  # actually exercise the backend: a truncated or wrong config passes listremotes
  local probe
  probe="$(rc lsd "$RCLONE_REMOTE" --max-depth 1 2>&1 | head -2 | tr '\n' ' ' || true)"
  log "remote probe: ${probe:-<empty>}"
}

remote_in() {
  [ -n "$RCLONE_REMOTE" ] || return 0
  mkdir -p "$SCENE_DIR" "$FRAMES_DIR"
  # create them if this is the first run, so a missing folder is not an "ERROR"
  rc mkdir "$RCLONE_REMOTE/frames" "$RCLONE_REMOTE/out" >/dev/null 2>&1 || true
  log "remote: pulling scene from $RCLONE_REMOTE/scene"
  rc copy "$RCLONE_REMOTE/scene" "$SCENE_DIR" 2>&1 | tail -2 || warn "scene pull failed"
  log "remote: pulling any finished frames from $RCLONE_REMOTE/frames"
  rc copy "$RCLONE_REMOTE/frames" "$FRAMES_DIR" 2>&1 | tail -2 || true
  local n; n="$(find "$FRAMES_DIR" -name 'f*.png' 2>/dev/null | wc -l)"
  log "remote: $n frames now on disk"
}

remote_sync() {
  [ -n "$RCLONE_REMOTE" ] || return 0
  local n
  n="$(find "$FRAMES_DIR" -name 'f*.png' 2>/dev/null | wc -l)"
  [ "$n" -gt 0 ] || return 0
  log "remote: syncing $n frames -> $RCLONE_REMOTE/frames"
  rc copy "$FRAMES_DIR" "$RCLONE_REMOTE/frames" 2>&1 | tail -2 || warn "frame sync failed"
}

remote_out() {
  [ -n "$RCLONE_REMOTE" ] || return 0
  [ -d "$OUT" ] || return 0
  log "remote: pushing $OUT -> $RCLONE_REMOTE/out"
  rc copy "$OUT" "$RCLONE_REMOTE/out" 2>&1 | tail -2 || warn "output push failed"
}

# --------------------------------------------------------------- scene
fetch_scene() {
  mkdir -p "$SCENE_DIR" "$FRAMES_DIR" "$OUT"

  if [ -z "$SCENE" ] || [ ! -f "$SCENE" ]; then
    for cand in "$SCENE_DIR/scene.blend" /opt/carrender/scene.blend; do
      [ -f "$cand" ] && { SCENE="$cand"; break; }
    done
  fi

  if [ -n "$SCENE_URL" ] && { [ -z "$SCENE" ] || [ ! -f "$SCENE" ]; }; then
    log "downloading scene: ${SCENE_URL%%\?*}"
    curl -fSL --retry 3 --retry-delay 2 -o "$SCENE_DIR/scene.blend" "$SCENE_URL" \
      || die "scene download failed"
    SCENE="$SCENE_DIR/scene.blend"
    if [ -n "$SCENE_SHA256" ]; then
      log "scene sha256 $(sha "$SCENE") (expect $SCENE_SHA256)"
      [ "$(sha "$SCENE")" = "$SCENE_SHA256" ] || die "scene sha256 mismatch"
    fi
  fi

  if [ -z "$SCENE" ] || [ ! -f "$SCENE" ]; then
    SCENE="$(find /data /opt/carrender -maxdepth 3 -name '*.blend' \
              -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
  fi
  [ -n "$SCENE" ] && [ -f "$SCENE" ] \
    || die "no scene: set RCLONE_REMOTE + RCLONE_CONFIG_B64, or SCENE_URL, or mount one at /data"
  log "scene: $SCENE ($(du -h "$SCENE" | cut -f1))"
}

# --------------------------------------------------- incremental state
sync_out() {
  remote_sync
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

  # A crashed probe used to look identical to "this host has no GPU", which
  # silently pushed a 32 spp render onto the CPU with no denoiser.  Keep the
  # requested device and let render.py's own fallback chain decide instead.
  if echo "$out" | grep -q '^PREFLIGHT_FAILED=1'; then
    warn "preflight probe FAILED (not the same as no GPU) - using the requested" \
    warn "device/denoiser ($DEVICE/$DENOISER) and letting render.py fall back"
    pf_device="$DEVICE"; pf_den="$DENOISER"
  fi
  pf_device="${pf_device:-CPU}"; pf_den="${pf_den:-NONE}"

  # The Colab failure mode: the enum accepts OPTIX but the render then dies with
  # "Unable to load denoiser weights".  Fall back to OIDN and say so loudly.
  if [ "$pf_den" = "OPTIX" ] && echo "$out" | grep -qiE 'unable to load denoiser|denoiser weights'; then
    warn "OptiX denoiser weights missing on this host -> OIDN (CPU)"
    warn "OIDN needs vCPUs: 39 of 48 s/frame on a 2-vCPU box in the project notes"
    pf_den="OIDN"
  fi
  if echo "$out" | grep -qi 'OptiX initialization failed'; then
    warn "OPTIX INIT FAILED on this host: $(echo "$out" | grep -i 'OptiX initialization failed' | head -1)"
    warn "OptiX needs the driver's libnvoptix.so.1; the 'driver libs' line above says what was found."
    warn "Without it cycles can only denoise with OIDN (CPU), which needs vCPUs."
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

  local chunk="$CHUNK"
  [ -n "$FRAMES" ] && chunk=0     # explicit frame list: one pass

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
  remote_out
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
  preflight) setup_rclone; remote_in; fetch_scene; preflight ;;
  render)
    setup_rclone
    remote_in
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
    setup_rclone; remote_in; fetch_scene; preflight
    F0="$(blender -b "$SCENE" --python-expr \
          'import bpy;print("CAR_F0",bpy.context.scene.frame_start)' 2>/dev/null \
          | sed -n 's/^CAR_F0 //p' | tail -1)"
    F0="${F0:-1}"
    FRAMES="$F0,$((F0 + 1)),$((F0 + 2)),$((F0 + 3))"
    TAG="bench"; ENCODE=0
    log "bench frames: $FRAMES (first frame includes the BVH build)"
    do_render
    ;;
  encode) setup_rclone; remote_in; fetch_scene; do_encode; upload ;;
  shell) exec /bin/bash ;;
  *) die "unknown command '$cmd' (render|preflight|encode|bench|shell)" ;;
esac
