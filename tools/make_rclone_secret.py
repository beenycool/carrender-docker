#!/usr/bin/env python3
"""make_rclone_secret.py - turn an rclone.conf into env-var values for carrender.

A 696-character single-line secret pasted into a web env-var field tends to arrive
truncated or quoted, which shows up in the container as "base64: invalid input".
This prints the value in equal parts, labelled for the RCLONE_CONFIG_B64,
RCLONE_CONFIG_B64_2, ... variables the container concatenates.

Note: the container needs the FULL config, including the short-lived
access_token.  rclone treats a token blob with an empty access_token as invalid
and drops it together with the refresh token, so a stripped-down config does not
work - only the real thing does.

    python3 tools/make_rclone_secret.py                 # default 2 parts
    python3 tools/make_rclone_secret.py --parts 3
    python3 tools/make_rclone_secret.py --conf /path/to/rclone.conf
    python3 tools/make_rclone_secret.py --verify 696    # check a length you pasted
"""
import argparse
import base64
import os
import sys


def default_conf():
    for p in (os.path.expanduser('~/.config/rclone/rclone.conf'),
              os.path.expanduser('~/.rclone.conf'),
              os.path.expandvars(r'%APPDATA%\rclone\rclone.conf')):
        if p and os.path.exists(p):
            return p
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--conf', default=default_conf())
    ap.add_argument('--parts', type=int, default=2)
    ap.add_argument('--verify', type=int, metavar='LEN',
                    help='only check that a value of this length decodes')
    args = ap.parse_args()

    if args.verify is not None:
        n = args.verify
        print('length %d: %s' % (n, 'divisible by 4 - plausible' if n % 4 == 0
                                 else 'NOT divisible by 4 - it was truncated'))
        return 0 if n % 4 == 0 and n > 64 else 1

    if not args.conf or not os.path.exists(args.conf):
        print('no rclone.conf found - pass --conf', file=sys.stderr)
        return 1

    raw = open(args.conf, 'rb').read()
    b64 = base64.b64encode(raw).decode()
    n = max(1, args.parts)
    size = -(-len(b64) // n)          # ceil
    parts = [b64[i:i + size] for i in range(0, len(b64), size)]

    print('source      : %s' % args.conf)
    print('config      : %d bytes' % len(raw))
    print('base64      : %d chars, split into %d part(s)' % (len(b64), len(parts)))
    if len(b64) % 4:
        print('WARNING: base64 length is not a multiple of 4 - the source file may be corrupt')
    print()
    for i, part in enumerate(parts):
        var = 'RCLONE_CONFIG_B64' + ('' if i == 0 else '_%d' % (i + 1))
        print('--- %s  (%d chars) ---' % (var, len(part)))
        print(part)
        print()
    print('Paste each block into the matching variable, all as secrets.')
    print('The container logs "config: + _N" for each extra part it receives,')
    print('and the total it worked out - check that total equals %d.' % len(b64))
    return 0


if __name__ == '__main__':
    sys.exit(main())
