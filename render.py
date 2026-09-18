"""render.py - resumable headless renderer, run inside Blender with the scene loaded.

    blender -b scene.blend -P /opt/carrender/render.py

Environment (all optional):

    RES_PCT    50       resolution_percentage  (50 -> 1080x1920 for this 9:16 scene)
    SAMPLES    32       cycles.samples
    BOUNCES    6        cycles.max_bounces
    TEXLIMIT   2048     cycles.texture_limit_render (OFF | 1024 | 2048 | 4096)
    OUTDIR     /data/frames
    DEVICE     OPTIX    OPTIX | CUDA | CPU
    DENOISER   OPTIX    OPTIX | OPENIMAGEDENOISE | NONE
    PERSIST    1        r.use_persistent_data - BVH built once (24 -> 14.7 s/frame in
                        the project notes, so this is the single biggest win)
    STEP       1        render every Nth frame
    FRAMES     ""       explicit comma list, overrides STEP
    TAG        ""       appended to the file name: f%04d_TAG.png

Frames already on disk are skipped, so the entrypoint can re-run this after a
crash without redoing work.  Prints "RENDER DONE" when the range is complete.
Nothing is saved to the .blend.
"""
import os
import sys
import time

import bpy


def env(name, default):
    return os.environ.get(name, default)


RES_PCT = float(env('RES_PCT', '50'))
SAMPLES = int(env('SAMPLES', '32'))
BOUNCES = int(env('BOUNCES', '6'))
TEXLIMIT = env('TEXLIMIT', '2048')
OUTDIR = env('OUTDIR', '/data/frames')
DEVICE = env('DEVICE', 'OPTIX').upper()
DENOISER = env('DENOISER', 'OPTIX').upper()
PERSIST = env('PERSIST', '1') == '1'
STEP = max(1, int(env('STEP', '1')))
FRAMES = env('FRAMES', '').strip()
TAG = env('TAG', '').strip()
LIMIT = int(env('LIMIT', '0'))     # render at most N frames this pass (0 = all)

sc = bpy.context.scene
r = sc.render
cy = sc.cycles


def use_device(want):
    prefs = bpy.context.preferences.addons['cycles'].preferences
    for cand in ([want] if want == 'CPU' else [want, 'CUDA', 'CPU']):
        try:
            if cand != 'CPU':
                prefs.compute_device_type = cand
                prefs.get_devices()
                if not any(d.type == cand for d in prefs.devices):
                    continue
                for d in prefs.devices:
                    d.use = (d.type == cand)
            else:
                for d in prefs.devices:
                    d.use = False
            print('device: %s  %s' % (cand, [d.name for d in prefs.devices if d.use]))
            return cand
        except Exception as exc:
            print('device %s failed: %s' % (cand, exc))
    return 'CPU'


def set_denoiser(want):
    try:
        if want == 'NONE':
            cy.use_denoising = False
            return 'NONE'
        cy.use_denoising = True
        cy.denoiser = 'OPTIX' if want == 'OPTIX' else 'OPENIMAGEDENOISE'
        return want
    except Exception as exc:
        print('denoiser %s unavailable (%s) -> OPENIMAGEDENOISE' % (want, exc))
        cy.use_denoising = True
        try:
            cy.denoiser = 'OPENIMAGEDENOISE'
            return 'OIDN'
        except Exception:
            cy.use_denoising = False
            return 'NONE'


def name(f):
    return 'f%04d%s.png' % (f, ('_' + TAG) if TAG else '')


def main():
    dev = use_device(DEVICE)
    den = set_denoiser(DENOISER)
    cy.device = 'CPU' if dev == 'CPU' else 'GPU'

    r.resolution_percentage = int(RES_PCT)
    cy.samples = SAMPLES
    cy.max_bounces = BOUNCES
    r.use_persistent_data = PERSIST
    r.image_settings.file_format = 'PNG'
    r.use_file_extension = True
    try:
        cy.texture_limit_render = TEXLIMIT
    except Exception as exc:
        print('texture_limit_render not available: %s' % exc)

    if not sc.camera:
        sc.camera = bpy.data.objects.get('Camera')

    W = int(r.resolution_x * RES_PCT / 100.0)
    H = int(r.resolution_y * RES_PCT / 100.0)
    print('resolution %d x %d   samples %d   bounces %d   persistent %s   '
          'texlimit %s' % (W, H, SAMPLES, BOUNCES, PERSIST, TEXLIMIT))
    print('denoiser %s   motion blur %s   camera %s'
          % (den, r.use_motion_blur, sc.camera.name if sc.camera else 'NONE'))
    if W % 2 or H % 2:
        print('!! odd dimensions: the H.264 encode needs even W/H, use -vf scale or '
              'a RES_PCT that lands on even numbers')

    os.makedirs(OUTDIR, exist_ok=True)
    F0, F1 = sc.frame_start, sc.frame_end
    if FRAMES:
        todo = [int(x) for x in FRAMES.split(',') if x.strip()]
    else:
        todo = [f for f in range(F0, F1 + 1, STEP) if not os.path.exists(
            os.path.join(OUTDIR, name(f)))]
    total = (F1 - F0 + 1) // STEP if not FRAMES else len(FRAMES.split(','))
    if LIMIT and len(todo) > LIMIT:
        print('LIMIT=%d: rendering %d of %d queued frames this pass'
              % (LIMIT, LIMIT, len(todo)))
        todo = todo[:LIMIT]
    if not todo:
        print('RENDER DONE (nothing to do: %d/%d frames present)' % (total, total))
        return
    print('range %d..%d step %d | %d/%d present | rendering %d'
          % (F0, F1, STEP, total - len(todo), total, len(todo)), flush=True)

    t0 = time.time()
    times = []
    for n, f in enumerate(todo, 1):
        sc.frame_set(f)
        r.filepath = os.path.join(OUTDIR, 'f%04d%s' % (f, ('_' + TAG) if TAG else ''))
        t = time.time()
        bpy.ops.render.render(write_still=True)
        dt = time.time() - t
        times.append(dt)
        warm = times[1:]
        per = (sum(warm) / len(warm)) if warm else dt
        eta = per * (len(todo) - n)
        print('frame %4d  %3d/%3d  %6.1f s  |  %.1f s/frame  |  elapsed %.1f min  '
              'eta %.1f min' % (f, n, len(todo), dt, per, (time.time() - t0) / 60,
                                eta / 60), flush=True)

    # the caller loops, so only claim DONE when nothing is left on disk
    left = [f for f in range(F0, F1 + 1, STEP)
            if not os.path.exists(os.path.join(OUTDIR, name(f)))]
    if left and not FRAMES:
        print('CHUNK DONE: %d frames in %.1f min (%.2f s/frame mean), %d still missing'
              % (len(todo), (time.time() - t0) / 60, sum(times) / len(times), len(left)))
    else:
        print('RENDER DONE: %d frames in %.1f min (%.2f s/frame mean)'
              % (len(todo), (time.time() - t0) / 60, sum(times) / len(times)))


if __name__ in ('__main__', 'builtins'):
    try:
        main()
    except Exception:
        import traceback
        print('RENDER EXCEPTION')
        print(traceback.format_exc())
        sys.exit(1)
