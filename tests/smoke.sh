#!/usr/bin/env bash
# smoke.sh - exercises the entrypoint's Salad-specific control flow with a stub
# Blender: chunked rendering, the state tar push/pull, resume, ffmpeg encode and
# the pre-signed PUT upload.  Runs on any architecture (no GPU, no real Blender).
#
#   docker/tests/smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8099}"
STORE="$(mktemp -d)"
RSTORE="$(mktemp -d)"          # fake "cloud" for the rclone path
IMG=carrender:smoke
RCFG_B64="$(printf '[t]\ntype = local\n' | base64 -w0)"   # rclone: local backend
DKR="${DKR:-docker}"
FRAMES=5
CHUNK=2

pass=0; fail=0
ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# The containers write as root, so the temp dirs can end up root-owned and
# undeletable by the CI runner.  Never let cleanup change the script's exit code.
cleanup() {
  [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null || true
  local d
  for d in "$STORE" "$RSTORE"; do
    [ -n "$d" ] || continue
    rm -rf "$d" 2>/dev/null || sudo rm -rf "$d" 2>/dev/null || true
  done
  return 0
}
trap 'cleanup || true' EXIT

cat > "$STORE/server.py" <<'PY'
import http.server, os, sys
ROOT = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def _p(self): return os.path.join(ROOT, os.path.basename(self.path))
    def do_PUT(self):
        n = int(self.headers.get('Content-Length', 0))
        with open(self._p(), 'wb') as f: f.write(self.rfile.read(n))
        print('PUT %s %d bytes -> %s' % (self.path, n, self._p()), flush=True)
        self.send_response(200); self.end_headers()
    def do_GET(self):
        if os.path.exists(self._p()):
            d = open(self._p(), 'rb').read()
            self.send_response(200); self.send_header('Content-Length', str(len(d)))
            self.end_headers(); self.wfile.write(d)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[2])), H).serve_forever()
PY
python3 "$STORE/server.py" "$STORE" "$PORT" & SRV=$!
sleep 1

echo "== build =="
$DKR build -f "$ROOT/Dockerfile.smoke" -t "$IMG" "$ROOT" >/tmp/smoke_build.log 2>&1 \
  && echo "  built $IMG" || { tail -20 /tmp/smoke_build.log; exit 1; }

run() { # run <tag> <extra env...>
  local tag="$1"; shift
  $DKR run --rm --network host -e STUB_FRAMES="$FRAMES" -e CHUNK="$CHUNK" \
    -e STATE_URL="http://127.0.0.1:$PORT/frames.tar" \
    -e UPLOAD_URL="http://127.0.0.1:$PORT/carrender.mp4" \
    -e RES_PCT=10 -e SAMPLES=2 "$@" "$IMG" render 2>&1 | tee "/tmp/smoke_$tag.log"
}

echo "== pass 1: 5 frames, CHUNK=2 (chunks then encode then upload) =="
run p1
check "pass1 rendered in chunks (CHUNK DONE seen)"  "grep -q 'CHUNK DONE' /tmp/smoke_p1.log"
check "pass1 finished the range (RENDER DONE seen)" "grep -q 'RENDER DONE' /tmp/smoke_p1.log"
check "pass1 pushed the state tar"                  "grep -q 'state: pushed' /tmp/smoke_p1.log"
check "pass1 encoded the mp4"                       "grep -q 'wrote .*carrender.mp4' /tmp/smoke_p1.log"
check "pass1 uploaded the mp4"                      "grep -q 'uploaded carrender.mp4' /tmp/smoke_p1.log"
check "server holds frames.tar"                     "[ -s '$STORE/frames.tar' ]"
check "server holds carrender.mp4"                  "[ -s '$STORE/carrender.mp4' ]"
check "state tar has all $FRAMES frames"            "[ \"\$(tar -tzf '$STORE/frames.tar' | grep -c 'f[0-9]*.png')\" -eq $FRAMES ]"
# probe inside the smoke image so the test does not depend on host ffmpeg
check "mp4 is a real video"                         "$DKR run --rm -v $STORE:/x --entrypoint ffprobe $IMG -v error -show_entries stream=codec_name -of csv=p=0 /x/carrender.mp4 | grep -q h264"
check "ALL DONE printed"                            "grep -q 'ALL DONE' /tmp/smoke_p1.log"

echo "== pass 2: fresh container, must RESUME from the state tar =="
run p2
check "pass2 restored the frames"                   "grep -q 'state: restored $FRAMES frames' /tmp/smoke_p2.log"
check "pass2 rendered nothing new"                  "grep -qE 'nothing to do|RENDER DONE: 0 frames' /tmp/smoke_p2.log"
check "pass2 re-encoded from restored frames"       "grep -q 'wrote .*carrender.mp4' /tmp/smoke_p2.log"

echo "== pass 4: rclone remote (scene in, frames + video out) =="
mkdir -p "$RSTORE/bucket/scene"
printf 'not a real blend' > "$RSTORE/bucket/scene/scene.blend"
$DKR run --rm --network host -e STUB_FRAMES="$FRAMES" -e CHUNK="$CHUNK" \
  -e RCLONE_CONFIG_B64="$RCFG_B64" -e RCLONE_REMOTE="t:$RSTORE/bucket" \
  -v "$RSTORE:$RSTORE" -e RES_PCT=10 -e SAMPLES=2 "$IMG" render 2>&1 | tee /tmp/smoke_p4.log
check "rclone: pulled the scene from the remote"   "grep -q 'remote: pulling scene' /tmp/smoke_p4.log"
check "rclone: synced frames back up"              "grep -q 'remote: syncing' /tmp/smoke_p4.log"
check "rclone: pushed the mp4"                     "grep -q 'remote: pushing' /tmp/smoke_p4.log"
check "rclone: frames landed in the remote"        "[ \"\$(find '$RSTORE/bucket/frames' -name 'f*.png' | wc -l)\" -eq $FRAMES ]"
check "rclone: mp4 landed in the remote"           "[ -s '$RSTORE/bucket/out/carrender.mp4' ]"

echo "== pass 5: fresh container resumes from the rclone remote =="
$DKR run --rm --network host -e STUB_FRAMES="$FRAMES" -e CHUNK="$CHUNK" \
  -e RCLONE_CONFIG_B64="$RCFG_B64" -e RCLONE_REMOTE="t:$RSTORE/bucket" \
  -v "$RSTORE:$RSTORE" -e RES_PCT=10 -e SAMPLES=2 "$IMG" render 2>&1 | tee /tmp/smoke_p5.log
check "rclone: restored $FRAMES frames on restart" "grep -q 'remote: $FRAMES frames now on disk' /tmp/smoke_p5.log"
check "rclone: rendered nothing new"               "grep -qE 'nothing to do|RENDER DONE: 0 frames' /tmp/smoke_p5.log"

echo "== pass 6: rclone config paste handling =="
# a config that has been wrapped, quoted and had its padding stripped - which is
# exactly how a 696-char secret arrives from a terminal into an env-var field
CFG_PLAIN='[t]
type = local
'
M_OK="$(printf '%s' "$CFG_PLAIN" | base64 -w0)"
M_WRAP="'$(printf '%s' "$CFG_PLAIN" | base64 | tr -d '\n' | fold -w 8 | tr '\n' ' ')'"
mkdir -p "$RSTORE/b2/scene"
printf 'not a real blend' > "$RSTORE/b2/scene/scene.blend"
$DKR run --rm --network host -e STUB_FRAMES="$FRAMES" \
  -e RCLONE_CONFIG_B64="$M_WRAP" -e RCLONE_REMOTE="t:$RSTORE/b2" \
  -v "$RSTORE:$RSTORE" -e RES_PCT=10 -e SAMPLES=2 "$IMG" render > /tmp/smoke_p6.log 2>&1 || true
check "mangled config (wrapped+quoted+padded) still works" \
      "grep -q 'remotes: t:' /tmp/smoke_p6.log"
check "mangled config run rendered"                       "grep -q 'RENDER DONE' /tmp/smoke_p6.log"

rc7=0
$DKR run --rm --network host -e RCLONE_CONFIG_B64='not a config at all' \
  -e RCLONE_REMOTE="t:$RSTORE/b2" "$IMG" preflight > /tmp/smoke_p7.log 2>&1 || rc7=$?
check "garbage config fails with a clear message" \
      "grep -qE 'no \\[section\\]|neither base64' /tmp/smoke_p7.log"
check "garbage config exits non-zero"             "[ $rc7 -ne 0 ]"

# 13 chars of base64 can never decode (length % 4 == 1)
rc8=0
$DKR run --rm --network host \
  -e RCLONE_CONFIG_B64="$(printf '%s' "$CFG_PLAIN" | base64 -w0 | cut -c1-13)" \
  -e RCLONE_REMOTE="t:$RSTORE/b2" "$IMG" preflight > /tmp/smoke_p8.log 2>&1 || rc8=$?
check "undecodable config is refused"             "grep -q 'not valid base64' /tmp/smoke_p8.log"
check "undecodable config exits non-zero"         "[ $rc8 -ne 0 ]"

$DKR run --rm --network host -e STUB_FRAMES="$FRAMES" \
  -e RCLONE_CONFIG_B64="${M_OK:0:6}" -e RCLONE_CONFIG_B64_2="${M_OK:6:6}" \
  -e RCLONE_CONFIG_B64_3="${M_OK:12:6}" -e RCLONE_CONFIG_B64_4="${M_OK:18:6}" \
  -e RCLONE_REMOTE="t:$RSTORE/b2" -v "$RSTORE:$RSTORE" \
  -e RES_PCT=10 -e SAMPLES=2 "$IMG" render > /tmp/smoke_p9.log 2>&1 || true
# no '$' in the pattern: check() evals its argument, and an unescaped $ expands
# under `set -u` and kills the script (which is how this test first failed)
check "config split across four env vars works"  "grep -q 'B64_4 (6 chars)' /tmp/smoke_p9.log"
check "split config reported the full length"     "grep -q \"config: total ${#M_OK} chars\" /tmp/smoke_p9.log"
check "split config run rendered"                 "grep -q 'RENDER DONE' /tmp/smoke_p9.log"

echo "== pass 3: preflight only =="
$DKR run --rm --network host -e STUB_FRAMES="$FRAMES" "$IMG" preflight 2>&1 | tee /tmp/smoke_p3.log >/dev/null
check "preflight reports the device"                "grep -q 'device=OPTIX denoiser=OPTIX' /tmp/smoke_p3.log"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
