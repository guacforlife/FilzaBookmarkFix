#!/usr/bin/env python3
"""Dry-run FilzaBookmarkFix's normalisation against a copy of Filza's prefs plist.

Reports every rewrite and duplicate-drop without touching the device. Keep the
norm() logic here in step with FBFNormalize() in FilzaBookmarkFix.m.

    scp <device>:/var/jb/var/mobile/Library/Preferences/com.tigisoftware.Filza.plist /tmp/
    python3 preview.py /tmp/com.tigisoftware.Filza.plist
"""
import plistlib, sys, re
JB = re.compile(r'/\.jbroot-[0-9A-Fa-f]+(?=/|$)')

def norm(s):
    if not isinstance(s, str) or not s: return None
    scheme = ''
    if s.startswith('file://'):
        scheme, body = 'file://', s[7:]
    elif '://' in s:
        return None                      # smb://, music://, apps://, mountpoints://
    else:
        body = s
    if body.startswith('[jbroot]'):   body = body[8:] or '/'
    elif body.startswith('[rootfs]'): body = '/rootfs' + body[8:]
    m = None
    for m in JB.finditer(body): pass     # last match
    if m: body = body[m.end():] or '/'
    out = scheme + body
    return out if out != s else None

d = plistlib.load(open(sys.argv[1],'rb'))
print("=== FavoritedLinks ===")
seen, keep = set(), []
for e in d.get('FavoritedLinks', []):
    p = e.get('path',''); n = norm(p)
    if n: print(f"  {e.get('name')!r}\n    - {p}\n    + {n}")
    final = n or p
    if n and final in seen:
        print(f"    !! DROP as duplicate of an earlier bookmark")
        continue
    seen.add(final); keep.append(e)
print(f"  -> {len(d.get('FavoritedLinks',[]))} bookmarks in, {len(keep)} out")

print("\n=== RecentItems ===")
c = 0
for sec, items in sorted(d.get('RecentItems',{}).items()):
    for it in items:
        for k in ('fileUrl','parentUrl','sourceUrl','sourceParentUrl'):
            v = it.get(k)
            n = norm(v) if v else None
            if n:
                c += 1
                if c <= 4: print(f"  [{sec}] {k}\n    - {v}\n    + {n}")
print(f"  -> {c} RecentItems strings rewritten")
