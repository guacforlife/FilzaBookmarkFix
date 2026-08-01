// FilzaBookmarkFix — repair Filza bookmarks broken by roothide's moving jbroot.
//
// THE PROBLEM
// Every re-jailbreak gives roothide a fresh jbroot container UUID. Filza stores
// its bookmarks ("FavoritedLinks") and recents ("RecentItems") as absolute
// paths, so any entry the user created by browsing in through /rootfs/... has a
// now-dead .jbroot-<HEX> component baked into it and lands on nothing.
//
// THE FIX
// Inside a jailbreak app the namespace root IS the jbroot, so
//   /rootfs/private/var/mobile/Containers/Shared/AppGroup/.jbroot-<HEX>/var/tmp
// and
//   /var/tmp
// are literally the same directory (verified by inode). Stripping the
// prefix up to and including the .jbroot-<HEX> component therefore preserves
// the destination while making the path UUID-free — so it survives every future
// re-jailbreak instead of needing repair again. Stale entries are healed once
// and stay healed; the tweak only has work to do when a new bookmark is made
// the long way round through /rootfs.
//
// This runs from a constructor, before UIApplicationMain, so Filza reads the
// repaired values rather than the stale ones.
//
// TWO NAMESPACES, DON'T CONFUSE THEM
// Filza is launched by SpringBoard, so its process runs in the REAL filesystem
// namespace: raw POSIX I/O from this dylib writing "/var/tmp/x" lands in the
// real /var/tmp (which SSH, being in the jbroot namespace, sees as
// /rootfs/private/var/tmp/x). Filza's *browser* is a separate matter — it does
// its own jbroot mapping, which is why "/rootfs" is one of its default
// bookmarks despite no such directory existing in the real root, and why Filza
// records a trash operation on browser-path /var/mobile/Library/Filza/.Trash as
// real path <jbroot>/var/mobile/Library/Filza/.Trash. Bookmark strings live in
// that browser space, so stripping to "/var/tmp" targets the jbroot copy —
// exactly where the stale path used to point.
//
// Consequence: use NSHomeDirectory() (= CFFIXED_USER_HOME = <jbroot>/var/mobile)
// for anything the user should be able to find in Filza itself. A literal
// "/var/mobile" from here would land in the real one, invisible to the browser.

#import <Foundation/Foundation.h>
#import <sys/stat.h>

static NSString *const kFavoritesKey = @"FavoritedLinks";
static NSString *const kRecentsKey   = @"RecentItems";
static NSString *const kLogName      = @"filzabookmarkfix.log";
static const NSUInteger kBackupsKept = 5;

// Log and backups both live here. Under the home directory, not a literal
// /var/mobile — see the namespace note above. NSHomeDirectory() in Filza is
// <jbroot>/var/mobile (verified on-device), so this lands somewhere Filza's own
// browser can reach at /var/mobile/Library/FilzaBookmarkFix and a bad repair
// can be undone from the device. A literal "/var/mobile" would write to the
// real one instead, which the browser never shows.
static NSString *FBFSupportDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/FilzaBookmarkFix"];
        if ([[NSFileManager defaultManager] createDirectoryAtPath:d
                                      withIntermediateDirectories:YES
                                                       attributes:nil error:NULL])
            dir = d;
        else
            dir = NSTemporaryDirectory();
    });
    return dir;
}

#pragma mark - Logging

static NSString *FBFLogPath(void) {
    return [FBFSupportDir() stringByAppendingPathComponent:kLogName];
}

static void FBFLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSString *path = FBFLogPath();
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        chmod(path.fileSystemRepresentation, 0644);
    }
}

#pragma mark - Path normalisation

// Returns the repaired string, or nil when the input already needs no change.
static NSString *FBFNormalize(id input) {
    if (![input isKindOfClass:[NSString class]]) return nil;
    NSString *s = (NSString *)input;
    if (s.length == 0) return nil;

    NSString *scheme = @"";
    NSString *body   = s;
    if ([s hasPrefix:@"file://"]) {
        scheme = @"file://";
        body   = [s substringFromIndex:scheme.length];
    } else if ([s rangeOfString:@"://"].location != NSNotFound) {
        return nil;  // smb://, music://, apps://, mountpoints:// are not filesystem paths
    }

    // Filza writes these display tokens into some entries; expand them so the
    // regex below sees a real path.
    if ([body hasPrefix:@"[jbroot]"]) {
        body = [body substringFromIndex:8];
        if (body.length == 0) body = @"/";
    } else if ([body hasPrefix:@"[rootfs]"]) {
        body = [@"/rootfs" stringByAppendingString:[body substringFromIndex:8]];
    }

    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // A whole path component named .jbroot-<hex>, under either
        // Containers/Shared/AppGroup or Containers/Bundle/Application.
        re = [NSRegularExpression regularExpressionWithPattern:@"/\\.jbroot-[0-9A-Fa-f]+(?=/|$)"
                                                      options:0
                                                        error:NULL];
    });
    if (re) {
        NSArray<NSTextCheckingResult *> *matches =
            [re matchesInString:body options:0 range:NSMakeRange(0, body.length)];
        NSTextCheckingResult *last = matches.lastObject;  // deepest jbroot wins
        if (last) {
            NSUInteger end = NSMaxRange(last.range);
            body = (end < body.length) ? [body substringFromIndex:end] : @"/";
        }
    }

    NSString *out = [scheme stringByAppendingString:body];
    return [out isEqualToString:s] ? nil : out;
}

#pragma mark - Backup

static void FBFBackup(NSDictionary *original) {
    NSFileManager *fm  = [NSFileManager defaultManager];
    NSString      *dir = FBFSupportDir();

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    df.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *file = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"bookmarks-%@.plist",
                       [df stringFromDate:[NSDate date]]]];

    if ([original writeToFile:file atomically:YES])
        FBFLog(@"  backup -> %@", file);

    // Timestamped names sort chronologically; keep only the newest few. Match the
    // backup prefix explicitly — the log file shares this directory.
    NSPredicate *isBackup = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'bookmarks-'"];
    NSArray *all = [[[fm contentsOfDirectoryAtPath:dir error:NULL]
                     filteredArrayUsingPredicate:isBackup]
                    sortedArrayUsingSelector:@selector(compare:)];
    if (all.count > kBackupsKept) {
        for (NSString *stale in [all subarrayWithRange:NSMakeRange(0, all.count - kBackupsKept)])
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:stale] error:NULL];
    }
}

#pragma mark - Repairs

// Rewrites stale bookmark paths and collapses entries that a rewrite turned
// into an exact duplicate of an earlier one. Only ever drops an entry we
// rewrote, so bookmarks the user deliberately duplicated are left alone.
static NSArray *FBFRepairFavorites(NSArray *links, NSMutableArray *log) {
    NSMutableArray *out  = [NSMutableArray arrayWithCapacity:links.count];
    NSMutableSet   *seen = [NSMutableSet set];
    NSUInteger fixed = 0, dropped = 0;

    for (id obj in links) {
        if (![obj isKindOfClass:[NSDictionary class]]) { [out addObject:obj]; continue; }
        NSDictionary *entry = (NSDictionary *)obj;

        NSString *path    = [entry[@"path"] isKindOfClass:[NSString class]] ? entry[@"path"] : nil;
        NSString *newPath = FBFNormalize(path);
        NSString *final   = newPath ?: path;

        if (newPath && final && [seen containsObject:final]) {
            [log addObject:[NSString stringWithFormat:@"  drop dup  %@  (was %@)",
                            entry[@"name"] ?: @"?", path]];
            dropped++;
            continue;
        }
        if (final) [seen addObject:final];

        if (!newPath) { [out addObject:entry]; continue; }

        NSMutableDictionary *m = [entry mutableCopy];
        m[@"path"] = newPath;
        // Some entries were saved with the stale path as their label too.
        NSString *newName = FBFNormalize(entry[@"name"]);
        if (newName) m[@"name"] = newName;
        [out addObject:m];
        [log addObject:[NSString stringWithFormat:@"  fix  %@\n         -> %@", path, newPath]];
        fixed++;
    }

    if (fixed == 0 && dropped == 0) return nil;

    // Removing entries leaves gaps in `order`; renumber so a bookmark Filza
    // appends later cannot collide with an existing index.
    if (dropped > 0) {
        for (NSUInteger i = 0; i < out.count; i++) {
            id e = out[i];
            if (![e isKindOfClass:[NSDictionary class]] || !((NSDictionary *)e)[@"order"]) continue;
            NSMutableDictionary *m = [e mutableCopy];
            m[@"order"] = @(i);
            out[i] = m;
        }
    }

    [log addObject:[NSString stringWithFormat:@"  bookmarks: %lu fixed, %lu duplicate(s) dropped, %lu kept",
                    (unsigned long)fixed, (unsigned long)dropped, (unsigned long)out.count]];
    return out;
}

static NSDictionary *FBFRepairRecents(NSDictionary *recents, NSMutableArray *log) {
    NSArray *urlKeys = @[@"fileUrl", @"parentUrl", @"sourceUrl", @"sourceParentUrl"];
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:recents.count];
    NSUInteger fixed = 0;

    for (id section in recents) {
        id value = recents[section];
        if (![value isKindOfClass:[NSArray class]]) { out[section] = value; continue; }

        NSMutableArray *items = [NSMutableArray array];
        for (id obj in (NSArray *)value) {
            if (![obj isKindOfClass:[NSDictionary class]]) { [items addObject:obj]; continue; }
            NSMutableDictionary *m = nil;
            for (NSString *key in urlKeys) {
                NSString *newURL = FBFNormalize(((NSDictionary *)obj)[key]);
                if (!newURL) continue;
                if (!m) m = [(NSDictionary *)obj mutableCopy];
                m[key] = newURL;
                fixed++;
            }
            [items addObject:(m ?: obj)];
        }
        out[section] = items;
    }

    if (fixed == 0) return nil;
    [log addObject:[NSString stringWithFormat:@"  recents: %lu url(s) rewritten", (unsigned long)fixed]];
    return out;
}

#pragma mark - Entry point

static void FBFRun(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    NSArray      *links   = [ud arrayForKey:kFavoritesKey];
    NSDictionary *recents = [ud dictionaryForKey:kRecentsKey];
    if (![links isKindOfClass:[NSArray class]]) links = nil;
    if (![recents isKindOfClass:[NSDictionary class]]) recents = nil;
    if (!links && !recents) return;

    NSMutableArray *log = [NSMutableArray array];
    NSArray      *newLinks   = links   ? FBFRepairFavorites(links, log) : nil;
    NSDictionary *newRecents = recents ? FBFRepairRecents(recents, log) : nil;
    if (!newLinks && !newRecents) return;  // nothing stale — the common case

    FBFLog(@"repairing stale jbroot paths:");

    NSMutableDictionary *backup = [NSMutableDictionary dictionary];
    if (links)   backup[kFavoritesKey] = links;
    if (recents) backup[kRecentsKey]   = recents;
    FBFBackup(backup);

    for (NSString *line in log) FBFLog(@"%@", line);

    if (newLinks)   [ud setObject:newLinks   forKey:kFavoritesKey];
    if (newRecents) [ud setObject:newRecents forKey:kRecentsKey];
    [ud synchronize];
    FBFLog(@"  done");
}

__attribute__((constructor))
static void FBFInit(void) {
    @autoreleasepool {
        // An uncaught exception here would abort Filza at launch. Never that.
        @try {
            FBFRun();
        } @catch (NSException *e) {
            FBFLog(@"EXCEPTION %@: %@", e.name, e.reason);
        }
    }
}
