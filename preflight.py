"""preflight.py - run inside Blender with the scene loaded, before any rendering.

Selects the compute device (OPTIX -> CUDA -> CPU) and renders ONE tiny frame with
the OptiX denoiser so the entrypoint can see whether the OptiX denoiser actually
loads on this host.  That distinction matters: on Colab's image `cycles.denoiser`
*accepts* 'OPTIX' but the render then fails with "Unable to load denoiser
weights", and the CPU fallback cost 39 of 48 s/frame on 2 vCPUs.

Prints machine-readable lines the entrypoint parses:

    PREFLIGHT_DEVICE=OPTIX
    PREFLIGHT_DENOISER=OPTIX
"""
import os
import subprocess
import sys

import bpy

PCT = int(float(os.environ.get('PREFLIGHT_PCT', '4')))   # must be an int
SAMPLES = int(os.environ.get('PREFLIGHT_SAMPLES', '2'))

sc = bpy.context.scene
r = sc.render
cy = sc.cycles
prefs = bpy.context.preferences.addons['cycles'].preferences


def pick_device():
    for want in ('OPTIX', 'CUDA'):
        try:
            prefs.compute_device_type = want
            prefs.get_devices()
        except Exception as exc:
            print('   %s: not available (%s)' % (want, exc))
            continue
        if any(d.type == want for d in prefs.devices):
            for d in prefs.devices:
                d.use = (d.type == want)
            return want, [d.name for d in prefs.devices if d.use]
    for d in prefs.devices:
        d.use = True
    return 'CPU', ['(cpu)']


def optix_libs():
    """OptiX comes from the DRIVER, injected by the container runtime - it is not
    part of the image.  If libnvoptix is missing, cycles cannot use it at all."""
    import glob
    found = []
    for pat in ('/usr/lib/x86_64-linux-gnu/libnvoptix*',
                '/usr/lib64/libnvoptix*',
                '/usr/share/nvidia/nvoptix.bin',
                '/usr/lib/x86_64-linux-gnu/libcuda*'):
        found += glob.glob(pat)
    return sorted(set(found))


def vram():
    try:
        q = subprocess.run(['nvidia-smi',
                            '--query-gpu=name,driver_version,memory.total,memory.used',
                            '--format=csv,noheader'],
                           capture_output=True, text=True)
        return q.stdout.strip() or '(nvidia-smi gave nothing)'
    except Exception as exc:
        return '(no nvidia-smi: %s)' % exc


def main():
    device, names = pick_device()
    print('gpu        : %s' % vram())
    libs = optix_libs()
    print('driver libs: %s' % (', '.join(libs) if libs else
                               'NONE FOUND - /dev/nvidia* may not be exposed'))
    print('device     : %s  %s' % (device, names))
    cy.device = 'CPU' if device == 'CPU' else 'GPU'
    if device == 'CPU':
        print('!! no usable GPU - rendering on CPU will be ~30-50x slower')

    denoiser = 'NONE'
    if device != 'CPU':
        try:
            cy.use_denoising = True
            cy.denoiser = 'OPTIX'
            denoiser = 'OPTIX'
        except Exception as exc:
            print('   OptiX denoiser not selectable (%s); using OIDN' % exc)
            cy.denoiser = 'OPENIMAGEDENOISE'
            denoiser = 'OIDN'

    sv = dict(pct=r.resolution_percentage, smp=cy.samples, fmt=r.image_settings.file_format,
              ext=r.use_file_extension, fp=r.filepath, fr=sc.frame_current)
    try:
        r.resolution_percentage = PCT
        cy.samples = SAMPLES
        r.image_settings.file_format = 'PNG'
        r.use_file_extension = False
        r.filepath = '/tmp/preflight'
        sc.frame_set(sc.frame_start)
        bpy.ops.render.render(write_still=True)
        ok = os.path.exists('/tmp/preflight.png')
        print('probe render: %s (%d bytes)'
              % ('ok' if ok else 'NO FILE',
                 os.path.getsize('/tmp/preflight.png') if ok else 0))
    finally:
        r.resolution_percentage = sv['pct']
        cy.samples = sv['smp']
        r.image_settings.file_format = sv['fmt']
        r.use_file_extension = sv['ext']
        r.filepath = sv['fp']
        sc.frame_set(sv['fr'])

    print('PREFLIGHT_DEVICE=%s' % device)
    print('PREFLIGHT_DENOISER=%s' % denoiser)


if __name__ in ('__main__', 'builtins'):
    try:
        main()
    except Exception:
        import traceback
        print('PREFLIGHT EXCEPTION')
        print(traceback.format_exc())
        # Distinct marker: the entrypoint must NOT read this as "CPU only", it
        # means the PROBE failed.  Let the render script pick its own device.
        print('PREFLIGHT_FAILED=1')
        sys.exit(0)
