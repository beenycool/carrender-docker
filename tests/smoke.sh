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
IMG=carrender:smoke
DKR="${DKR:-docker}"
FRAMES=5
CHUNK=2

pass=0; fail=0
ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null || true; rm -rf "$STORE"; }
trap cleanup EXIT

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

echo "== pass 3: preflight only =="
$DKR run --rm --network host -e STUB_FRAMES="$FRAMES" "$IMG" preflight 2>&1 | tee /tmp/smoke_p3.log >/dev/null
check "preflight reports the device"                "grep -q 'device=OPTIX denoiser=OPTIX' /tmp/smoke_p3.log"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
