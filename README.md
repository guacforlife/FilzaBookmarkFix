# FilzaBookmarkFix

A jailbreak tweak that repairs **Filza bookmarks and recents** broken by roothide's
changing jbroot path.

|  | |
|---|---|
| **Bundle** | `com.tigisoftware.Filza` |
| **Jailbreak** | rootless / roothide (Dopamine). `THEOS_PACKAGE_SCHEME = rootless`, `ARCHS = arm64 arm64e` |
| **Tested** | iPhone 14 Pro Max, iOS 16.3.1, Dopamine + ElleKit |

## The problem

Every re-jailbreak gives roothide a fresh `.jbroot-<HEX>` container. Filza stores its
bookmarks (`FavoritedLinks`) and recents (`RecentItems`) as absolute paths, so any entry
you made by browsing in through `/rootfs/...` keeps a dead UUID and lands on nothing. The
dead UUIDs pile up — the device this was written on had accumulated five of them.

## What it does

Rather than re-point stale paths at the *current* jbroot (which would break again on the
next re-jailbreak), it strips each path back to its jbroot-relative form. Inside Filza's
browser the root **is** the jbroot, so

```
/rootfs/private/var/mobile/Containers/Shared/AppGroup/.jbroot-<HEX>/var/tmp
/var/tmp
```

are the same directory — verified by inode. Stripping the prefix up to and including the
`.jbroot-<HEX>` component preserves the destination and leaves the path UUID-free, so it
survives every future re-jailbreak. Stale entries are healed once and stay healed.

It also:

- expands Filza's `[jbroot]` / `[rootfs]` label tokens when they turn up in a stored path
- collapses entries that a rewrite turned into an exact duplicate of an earlier one, only
  ever dropping an entry it rewrote, so deliberate duplicates survive
- renumbers `order` when something is dropped

A first run on the development device took 19 bookmarks to 17 (5 paths fixed, 2 exact
duplicates collapsed) and repaired 19 recents URLs.

## How it works

A constructor-only dylib, no hooks. It runs before `UIApplicationMain` so Filza reads the
repaired values, and writes through `NSUserDefaults` rather than the plist file so
roothide's cfprefsd redirection applies. When nothing is stale it is a silent no-op.

### Two namespaces

Filza is launched by SpringBoard, so its **process** runs in the real filesystem namespace.
Raw POSIX I/O from this dylib writing `/var/tmp/x` lands in the real `/var/tmp`. Confirmed
from inside Filza:

```
NSHomeDirectory()                        = <jbroot>/var/mobile
NSTemporaryDirectory()                   = <jbroot>/var/tmp/
POSIX exists /rootfs                     = false
POSIX exists /var/mobile/RootHidePatcher = false
POSIX exists /var/tmp                    = true
```

Filza's **browser** is a separate matter — it does its own jbroot mapping, which is why
`/rootfs` is one of its default bookmarks despite no such directory existing in the real
root, and why Filza records a trash operation on browser-path
`/var/mobile/Library/Filza/.Trash` as real path `<jbroot>/var/mobile/Library/Filza/.Trash`.
Bookmark strings live in that browser space, which is what makes the rewrite above correct.

Consequence for anyone hacking on this: use `NSHomeDirectory()` for anything the user should
be able to find in Filza itself. A literal `/var/mobile` writes to the real one, invisible
to the browser.

## Log and backups

Both under `/var/mobile/Library/FilzaBookmarkFix/`, browsable in Filza itself:

- `filzabookmarkfix.log` — only written when something was actually repaired
- `bookmarks-<timestamp>.plist` — pre-repair copy of `FavoritedLinks` and `RecentItems`,
  newest 5 kept

If a repair ever goes wrong, restore by hand from the backup plist.

## Preview before installing

`preview.py` dry-runs the same normalisation against a copy of the plist without touching
anything:

```sh
scp <device>:/var/jb/var/mobile/Library/Preferences/com.tigisoftware.Filza.plist /tmp/
python3 preview.py /tmp/com.tigisoftware.Filza.plist
```

## What it cannot fix

A bookmark pointing into an app's `Containers/Data/Application/<UUID>` directory. Those
break when that **app** is reinstalled rather than on re-jailbreak, and nothing in the
bookmark records which app it was, so there is nothing to resolve it against. Delete those
by hand.

## Install

Add the repo to Sileo/Zebra and install **FilzaBookmarkFix**:

```
https://guacforlife.github.io/repo/
```

Or grab the `.deb` from [Releases](../../releases) and install it manually.

## Build

Requires [Theos](https://theos.dev).

```sh
export THEOS=~/theos
make package        # -> packages/com.guacforlife.filzabookmarkfix_<ver>_iphoneos-arm64.deb
```

A Filza-only tweak loads on app launch, so no respring is needed — just relaunch Filza
after installing.

## License

MIT
