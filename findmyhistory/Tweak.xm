// FindMyHistory — logs own/shared AirTag location + battery/firmware history locally, inside Find My's sandbox.
// Phase 3: two read-only hooks in Apple's SearchParty client layer, batched WAL SQLite, no main-thread I/O. On-device only.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sqlite3.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#import <substrate.h>
#import "FMHShared.h"

static os_log_t LOG;
#define FMH_LOG(fmt, ...) os_log(LOG, "[FMH] " fmt, ##__VA_ARGS__)

// Typed views of the SPOwner objects so selectors resolve unambiguously under ARC (ids match multiple SDK decls).
@protocol FMHResult <NSObject> - (NSDictionary *)locationsByBeaconIdentifier; @end
@protocol FMHLoc <NSObject>
- (double)latitude; - (double)longitude; - (double)horizontalAccuracy; - (NSDate *)timestamp; - (NSString *)source;
@end
@protocol FMHHandle <NSObject> - (NSString *)destination; @end
@protocol FMHBeacon <NSObject>
- (NSString *)type; - (NSUUID *)identifier; - (NSString *)name; - (NSString *)systemVersion; - (long long)batteryLevel;
- (NSString *)serialNumber; - (id<FMHHandle>)owner;
@end

// ---- state (all access on gStateQ) ----
static sqlite3 *gDB;
static dispatch_queue_t gStateQ;              // serial: owns gDB, gMeta, gPending, gLastTs
static NSMutableDictionary<NSString*, NSDictionary*> *gMeta;   // uuid -> {name, fw, batt, type, owned}
static NSMutableArray<NSDictionary*> *gPending;                // rows awaiting flush
static NSMutableDictionary<NSString*, NSNumber*> *gLastTs;     // uuid -> last fix ts (cheap dedup)
static NSMutableDictionary<NSString*, NSMutableArray*> *gLocBuf; // uuid -> [location dicts] seen before metadata
// Ownership (owned vs shared). Owner handles (emails) live ONLY in memory, never in the DB or logs.
static NSMutableDictionary<NSString*, NSNumber*> *gOwnerCount;  // owner handle -> #beacons owned (all types)
static NSMutableDictionary<NSString*, NSString*> *gDurianOwner; // AirTag uuid -> owner handle
static NSString *gMeHandle;    // ponytail: "me" = the handle owning the most beacons; upgrade to share-graph if it ever misclassifies
static NSMutableSet<NSString*> *gBackfilled;   // tags whose old rows have been labeled this session
static BOOL gFlushScheduled;
static const NSTimeInterval kLocBufMaxAge = 120.0;   // drop buffered locations older than this

// NOTE: battery is stored as the raw backend status byte (0/1/2…) only. The scale is NOT verified — observed values
// don't line up with any Find My low-battery warning, and the FMIPItemBatteryStatus enum ordering could make a higher
// number mean *better*. So we deliberately do NOT map it to Full/Low; the UI shows the raw value marked "unverified".

static NSString *dbPath(void) {
	NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/FindMyHistory"];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	return [dir stringByAppendingPathComponent:@"history.sqlite"];
}

static void openDB(void) {
	NSString *path = dbPath();
	if (sqlite3_open([path UTF8String], &gDB) != SQLITE_OK) { FMH_LOG("open failed: %{public}s", sqlite3_errmsg(gDB)); gDB = NULL; return; }
	char *err = NULL;
	sqlite3_exec(gDB, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", NULL, NULL, &err);
	sqlite3_exec(gDB,
		"CREATE TABLE IF NOT EXISTS locations("
		"id INTEGER PRIMARY KEY, tag_id TEXT NOT NULL, tag_name TEXT,"
		"lat REAL, lon REAL, h_acc REAL, timestamp REAL, source TEXT,"
		"battery_raw INTEGER, battery_label TEXT, firmware TEXT, is_owned INTEGER, created_at REAL, serial_number TEXT);"
		"CREATE INDEX IF NOT EXISTS idx_tag_time ON locations(tag_id, timestamp);"
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_dedup ON locations(tag_id, timestamp, lat, lon);",
		NULL, NULL, &err);
	if (err) { FMH_LOG("schema: %{public}s", err); sqlite3_free(err); }
	sqlite3_exec(gDB, "ALTER TABLE locations ADD COLUMN serial_number TEXT", NULL, NULL, NULL); // upgrade older DBs; no-op if present
	// retention prune (0 = keep forever)
	NSInteger retention = FMHSettings.shared.retentionDays;
	if (retention > 0) {
		sqlite3_stmt *st;
		if (sqlite3_prepare_v2(gDB, "DELETE FROM locations WHERE created_at < ?", -1, &st, NULL) == SQLITE_OK) {
			sqlite3_bind_double(st, 1, [[NSDate date] timeIntervalSince1970] - retention * 86400.0);
			sqlite3_step(st); sqlite3_finalize(st);
		}
	}
	FMH_LOG("db ready at %{public}@", path);
}

static void flushLocked(void) {   // call on gStateQ
	gFlushScheduled = NO;
	if (!gDB || gPending.count == 0) return;
	NSArray *rows = gPending; gPending = [NSMutableArray array];
	char *err = NULL; sqlite3_exec(gDB, "BEGIN", NULL, NULL, &err);
	sqlite3_stmt *st;
	const char *sql = "INSERT OR IGNORE INTO locations"
		"(tag_id,tag_name,lat,lon,h_acc,timestamp,source,battery_raw,battery_label,firmware,is_owned,created_at,serial_number)"
		" VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)";
	if (sqlite3_prepare_v2(gDB, sql, -1, &st, NULL) != SQLITE_OK) { sqlite3_exec(gDB, "ROLLBACK", NULL, NULL, NULL); return; }
	NSUInteger n = 0;
	for (NSDictionary *r in rows) {
		sqlite3_bind_text  (st, 1, [r[@"tag_id"] UTF8String], -1, SQLITE_TRANSIENT);
		id name = r[@"tag_name"]; name == [NSNull null] || !name ? sqlite3_bind_null(st, 2) : sqlite3_bind_text(st, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
		sqlite3_bind_double(st, 3, [r[@"lat"] doubleValue]);
		sqlite3_bind_double(st, 4, [r[@"lon"] doubleValue]);
		sqlite3_bind_double(st, 5, [r[@"h_acc"] doubleValue]);
		sqlite3_bind_double(st, 6, [r[@"timestamp"] doubleValue]);
		id src = r[@"source"]; src == [NSNull null] || !src ? sqlite3_bind_null(st, 7) : sqlite3_bind_text(st, 7, [src UTF8String], -1, SQLITE_TRANSIENT);
		sqlite3_bind_int64 (st, 8, [r[@"battery_raw"] longLongValue]);
		id blabel = r[@"battery_label"]; blabel == [NSNull null] || !blabel ? sqlite3_bind_null(st, 9) : sqlite3_bind_text(st, 9, [blabel UTF8String], -1, SQLITE_TRANSIENT);
		id fw = r[@"firmware"]; fw == [NSNull null] || !fw ? sqlite3_bind_null(st, 10) : sqlite3_bind_text(st, 10, [fw UTF8String], -1, SQLITE_TRANSIENT);
		sqlite3_bind_int   (st, 11, [r[@"is_owned"] intValue]);
		sqlite3_bind_double(st, 12, [r[@"created_at"] doubleValue]);
		id serial = r[@"serial"]; serial == [NSNull null] || !serial ? sqlite3_bind_null(st, 13) : sqlite3_bind_text(st, 13, [serial UTF8String], -1, SQLITE_TRANSIENT);
		if (sqlite3_step(st) == SQLITE_DONE && sqlite3_changes(gDB) > 0) n++;
		sqlite3_reset(st);
	}
	sqlite3_finalize(st);
	sqlite3_exec(gDB, "COMMIT", NULL, NULL, &err);
	if (n) FMH_LOG("flushed %lu rows", (unsigned long)n);
}

static void scheduleFlush(void) {   // call on gStateQ
	if (gFlushScheduled) return;
	gFlushScheduled = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), gStateQ, ^{ flushLocked(); });
}

// Build + enqueue one row by joining a buffered location dict with current metadata. Call on gStateQ.
static void appendRowLocked(NSString *uuid, NSDictionary *loc, NSDictionary *m) {
	if (!FMHSettings.shared.loggingEnabled || ![FMHSettings.shared isTagEnabled:uuid]) return;  // honor in-app settings
	double ts = [loc[@"ts"] doubleValue];
	NSNumber *last = gLastTs[uuid];
	if (last && fabs(last.doubleValue - ts) < 1.0) return;  // same fix re-delivered
	gLastTs[uuid] = @(ts);
	long long batt = [m[@"batt"] longLongValue];
	NSString *owner = gDurianOwner[uuid];
	int isOwned = (owner && gMeHandle) ? ([owner isEqualToString:gMeHandle] ? 1 : 0) : -1;
	[gPending addObject:@{
		@"tag_id": uuid,
		@"tag_name": m[@"name"] ?: [NSNull null],
		@"lat": loc[@"lat"], @"lon": loc[@"lon"], @"h_acc": loc[@"acc"], @"timestamp": @(ts),
		@"source": loc[@"src"] ?: [NSNull null],
		@"battery_raw": @(batt), @"battery_label": [NSNull null],  // scale unverified — raw value is the truth
		@"firmware": m[@"fw"] ?: [NSNull null],
		@"is_owned": @(isOwned),
		@"serial": m[@"serial"] ?: [NSNull null],
		@"created_at": @([[NSDate date] timeIntervalSince1970]),
	}];
	scheduleFlush();
}

// Tally an owner handle for ANY beacon (devices included) to resolve which handle is "me". Call on gStateQ.
static void tallyOwnerLocked(NSString *ownerHandle) {
	if (!ownerHandle.length) return;
	gOwnerCount[ownerHandle] = @(gOwnerCount[ownerHandle].integerValue + 1);
	NSString *best = gMeHandle; NSInteger bestN = best ? gOwnerCount[best].integerValue : -1;
	for (NSString *h in gOwnerCount) { NSInteger c = gOwnerCount[h].integerValue; if (c > bestN) { bestN = c; best = h; } }
	gMeHandle = best;
}

// Authoritatively (re)label ALL of a tag's rows from the FINAL "me". Only call from the end-of-batch pass, where
// gMeHandle is stable — calling it mid-batch locks in a transient wrong value (bug fixed 2026-10-29).
static void backfillLocked(NSString *uuid) {
	if (!gDB || !gMeHandle) return;
	NSString *owner = gDurianOwner[uuid]; if (!owner) return;
	if ([gBackfilled containsObject:uuid]) return;   // once per session; gMeHandle is final here
	id serial = gMeta[uuid][@"serial"]; NSString *sn = [serial isKindOfClass:[NSString class]] ? serial : nil;
	int isOwned = [owner isEqualToString:gMeHandle] ? 1 : 0;
	sqlite3_stmt *st;
	if (sqlite3_prepare_v2(gDB, "UPDATE locations SET is_owned=?, serial_number=COALESCE(serial_number,?) WHERE tag_id=?", -1, &st, NULL) == SQLITE_OK) {
		sqlite3_bind_int(st, 1, isOwned);
		sn ? sqlite3_bind_text(st, 2, [sn UTF8String], -1, SQLITE_TRANSIENT) : sqlite3_bind_null(st, 2);
		sqlite3_bind_text(st, 3, [uuid UTF8String], -1, SQLITE_TRANSIENT);
		if (sqlite3_step(st) == SQLITE_DONE) [gBackfilled addObject:uuid];
		sqlite3_finalize(st);
	}
}

// Store latest metadata for an AirTag (durian); drain any locations buffered before metadata arrived.
static void noteMeta(NSString *uuid, NSString *name, NSString *fw, long long batt, NSString *serial, NSString *ownerHandle) {
	if (!uuid) return;
	dispatch_async(gStateQ, ^{
		gMeta[uuid] = @{ @"name": name ?: [NSNull null], @"fw": fw ?: [NSNull null], @"batt": @(batt), @"serial": serial ?: [NSNull null] };
		if (ownerHandle.length) gDurianOwner[uuid] = ownerHandle;
		NSMutableArray *buf = gLocBuf[uuid];
		if (buf.count) { for (NSDictionary *loc in buf) appendRowLocked(uuid, loc, gMeta[uuid]); [gLocBuf removeObjectForKey:uuid]; }
		// backfill happens only in the end-of-batch pass (gMeHandle must be final).
	});
}

// Record a location. If the tag's metadata is known, log now; else buffer until metadata confirms it's an AirTag.
static void noteLocation(NSString *uuid, double lat, double lon, double acc, double ts, NSString *source) {
	if (!uuid) return;
	NSDictionary *loc = @{ @"lat": @(lat), @"lon": @(lon), @"acc": @(acc), @"ts": @(ts), @"src": source ?: [NSNull null], @"rx": @([[NSDate date] timeIntervalSince1970]) };
	dispatch_async(gStateQ, ^{
		NSDictionary *m = gMeta[uuid];
		if (m) { appendRowLocked(uuid, loc, m); return; }
		NSMutableArray *buf = gLocBuf[uuid];
		if (!buf) { buf = [NSMutableArray array]; gLocBuf[uuid] = buf; }
		[buf addObject:loc];
		if (buf.count > 50) [buf removeObjectAtIndex:0];
		// prune stale buffers (non-AirTag UUIDs that never get metadata)
		double now = [[NSDate date] timeIntervalSince1970];
		NSMutableArray *dead = [NSMutableArray array];
		for (NSString *k in gLocBuf) { NSArray *a = gLocBuf[k]; if (!a.count || now - [[a lastObject][@"rx"] doubleValue] > kLocBufMaxAge) [dead addObject:k]; }
		[gLocBuf removeObjectsForKeys:dead];
	});
}

// ---- hooks ----

%group Loc
%hook SPOwnerSessionLocationFetch
- (void)receivedUpdatedLocation:(id)result {
	@try {
		NSDictionary *byId = [result respondsToSelector:@selector(locationsByBeaconIdentifier)] ? [(id<FMHResult>)result locationsByBeaconIdentifier] : nil;
		for (NSUUID *key in byId) {
			NSString *uuid = [key respondsToSelector:@selector(UUIDString)] ? [key UUIDString] : [key description];
			id raw = byId[key];
			if ([raw isKindOfClass:[NSArray class]]) raw = [(NSArray *)raw lastObject];
			if (!raw || ![raw respondsToSelector:@selector(latitude)]) continue;
			id<FMHLoc> loc = (id<FMHLoc>)raw;
			double lat = [loc latitude], lon = [loc longitude], acc = [loc horizontalAccuracy];
			NSDate *d = [raw respondsToSelector:@selector(timestamp)] ? [loc timestamp] : nil;
			double ts = d ? [d timeIntervalSince1970] : [[NSDate date] timeIntervalSince1970];
			NSString *src = [raw respondsToSelector:@selector(source)] ? [loc source] : nil;
			noteLocation(uuid, lat, lon, acc, ts, src);
		}
	} @catch (__unused NSException *e) {}
	%orig;
}
%end
%end

%group Meta
%hook SPBeaconManagerSimpleBeaconUpdateInterface
- (void)receivedSimpleBeaconUpdates:(id)beacons {
	@try {
		for (id raw in beacons) {
			id<FMHBeacon> b = (id<FMHBeacon>)raw;
			// Tally owner across ALL beacon types (devices too) so "me" = the dominant owner.
			NSString *ownerHandle = nil;
			if ([raw respondsToSelector:@selector(owner)]) { id<FMHHandle> o = [b owner];
				if ([o respondsToSelector:@selector(destination)]) ownerHandle = [o destination]; }
			__block NSString *oh = ownerHandle; if (oh.length) dispatch_async(gStateQ, ^{ tallyOwnerLocked(oh); });
			if (![raw respondsToSelector:@selector(type)] || ![[b type] isEqualToString:@"durian"]) continue;  // AirTags only
			NSUUID *idf = [raw respondsToSelector:@selector(identifier)] ? [b identifier] : nil;
			NSString *uuid = [idf respondsToSelector:@selector(UUIDString)] ? [idf UUIDString] : nil;
			NSString *name = [raw respondsToSelector:@selector(name)] ? [b name] : nil;
			NSString *fw = [raw respondsToSelector:@selector(systemVersion)] ? [b systemVersion] : nil;
			long long batt = [raw respondsToSelector:@selector(batteryLevel)] ? [b batteryLevel] : -1;
			NSString *serial = [raw respondsToSelector:@selector(serialNumber)] ? [b serialNumber] : nil;
			noteMeta(uuid, name, fw, batt, serial, ownerHandle);
		}
		// after the whole batch (so gMeHandle is final on the serial queue), label any still-unlabeled tags.
		dispatch_async(gStateQ, ^{ for (NSString *u in [gDurianOwner allKeys]) backfillLocked(u); });
	} @catch (__unused NSException *e) {}
	%orig;
}
%end
%end

// Force a flush on background/terminate, protected by a background-task assertion so suspension can't race it.
// ---- detail screen (UI injection + coverage #1: log the on-screen location when a tag is opened) ----

static long fmhIvarOffset(Class c, const char *n) { Ivar iv = class_getInstanceVariable(c, n); return iv ? ivar_getOffset(iv) : -1; }
static BOOL fmhIsUUID(NSString *s) { return s.length == 36 && [s characterAtIndex:8] == '-'; }

// Read a Swift String (16 bytes) at a KNOWN-good offset: small-string (inline) or bridged NSString.
// Hardened: a large-string backing pointer is validated as a real heap object before it is ever messaged
// (scanning arbitrary memory and messaging it is what crashed Find My — never reintroduce that).
static NSString *fmhReadSwiftString(uint8_t *p) {
	uint8_t last = p[15];
	if (last & 0x80) { int cnt = last & 0x0f; if (cnt > 15) return nil; char buf[16] = {0}; for (int i = 0; i < cnt; i++) buf[i] = p[i]; return [[NSString alloc] initWithBytes:buf length:cnt encoding:NSUTF8StringEncoding]; }
	uintptr_t v = (*(uintptr_t *)(p + 8)) & 0x7ffffffffff8ULL;
	if (v < 0x100000000ULL) return nil;               // reject null/low/tagged
	if (malloc_size((const void *)v) == 0) return nil; // must be a live heap allocation before we touch it
	@try { __unsafe_unretained id o = (__bridge id)(void *)v; if ([o isKindOfClass:[NSString class]]) return [o copy]; } @catch (__unused NSException *e) {}
	return nil;
}

// From the item detail VC: returns the tag UUID (itemViewModel.identifier, a known ivar offset). No memory scanning.
static NSString *fmhDetailTagId(UIViewController *vc) {
	Ivar dsIvar = class_getInstanceVariable(object_getClass(vc), "dataSource");
	if (!dsIvar) return nil;
	id ds = object_getIvar(vc, dsIvar);
	if (!ds) return nil;
	long vmOff = fmhIvarOffset(object_getClass(ds), "itemViewModel");
	if (vmOff < 0) return nil;
	NSString *uuid = fmhReadSwiftString((uint8_t *)(__bridge void *)ds + vmOff);
	return fmhIsUUID(uuid) ? uuid : nil;
}

static const char *kFMHButtonKey = "fmh.btn";

static void fmhInstallHistoryButton(UIViewController *vc, NSString *uuid) {
	if (!uuid || objc_getAssociatedObject(vc, kFMHButtonKey)) return;
	objc_setAssociatedObject(vc, kFMHButtonKey, @YES, OBJC_ASSOCIATION_RETAIN);
	UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
	[btn setImage:[UIImage systemImageNamed:@"clock.arrow.circlepath" withConfiguration:cfg] forState:UIControlStateNormal];
	btn.translatesAutoresizingMaskIntoConstraints = NO;
	btn.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.92];
	btn.layer.cornerRadius = 22; btn.tintColor = UIColor.systemBlueColor;
	btn.accessibilityLabel = @"History";
	__weak UIViewController *wvc = vc;
	[btn addAction:[UIAction actionWithHandler:^(__unused UIAction *a) {
		FMHHistoryViewController *h = [[FMHHistoryViewController alloc] initWithTagId:uuid name:nil];
		UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:h];
		[wvc presentViewController:nav animated:YES completion:nil];
	}] forControlEvents:UIControlEventTouchUpInside];
	[vc.view addSubview:btn];
	[vc.view bringSubviewToFront:btn];
	// Sit to the LEFT of Apple's ✕ close button (top-trailing of the card), as a separate, easy target.
	[NSLayoutConstraint activateConstraints:@[
		[btn.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-66],
		[btn.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:6],
		[btn.widthAnchor constraintEqualToConstant:44], [btn.heightAnchor constraintEqualToConstant:44],
	]];
}

static void (*orig_detailVDA)(UIViewController *, SEL, BOOL);
static void fmh_detailVDA(UIViewController *vc, SEL _cmd, BOOL animated) {
	orig_detailVDA(vc, _cmd, animated);
	@try { NSString *uuid = fmhDetailTagId(vc); if (uuid) fmhInstallHistoryButton(vc, uuid); } @catch (__unused NSException *e) {}
}

static void onBackground(void) {
	UIApplication *app = [UIApplication sharedApplication];
	__block UIBackgroundTaskIdentifier bg = [app beginBackgroundTaskWithName:@"fmh.flush" expirationHandler:^{}];
	dispatch_async(gStateQ, ^{
		flushLocked();
		if (gDB) sqlite3_wal_checkpoint_v2(gDB, NULL, SQLITE_CHECKPOINT_PASSIVE, NULL, NULL);
		if (bg != UIBackgroundTaskInvalid) { [app endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
	});
}

%ctor {
	LOG = os_log_create("com.liam.findmyhistory", "tweak");
	gStateQ = dispatch_queue_create("com.liam.findmyhistory.state", DISPATCH_QUEUE_SERIAL);
	gMeta = [NSMutableDictionary dictionary];
	gPending = [NSMutableArray array];
	gLastTs = [NSMutableDictionary dictionary];
	gLocBuf = [NSMutableDictionary dictionary];
	gOwnerCount = [NSMutableDictionary dictionary];
	gDurianOwner = [NSMutableDictionary dictionary];
	gBackfilled = [NSMutableSet set];
	dispatch_async(gStateQ, ^{ openDB(); });

	NSInteger inited = 0;
	if (objc_getClass("SPBeaconManagerSimpleBeaconUpdateInterface")) { %init(Meta); inited++; } else FMH_LOG("missing SPBeaconManagerSimpleBeaconUpdateInterface");
	if (objc_getClass("SPOwnerSessionLocationFetch")) { %init(Loc); inited++; } else FMH_LOG("missing SPOwnerSessionLocationFetch");

	Class detailCls = objc_getClass("FindMy.FMItemDetailContentViewController");
	if (detailCls) { MSHookMessageEx(detailCls, @selector(viewDidAppear:), (IMP)fmh_detailVDA, (IMP *)&orig_detailVDA); FMH_LOG("detail hook installed"); }
	else FMH_LOG("missing FMItemDetailContentViewController");
	// Resilience: healthy only if BOTH classes AND their hooked selectors still exist (a renamed selector would
	// otherwise leave %init succeeding while the hook never fires).
	Class locCls = objc_getClass("SPOwnerSessionLocationFetch"), metaCls = objc_getClass("SPBeaconManagerSimpleBeaconUpdateInterface");
	BOOL healthy = (inited == 2)
		&& locCls && class_getInstanceMethod(locCls, @selector(receivedUpdatedLocation:))
		&& metaCls && class_getInstanceMethod(metaCls, @selector(receivedSimpleBeaconUpdates:));
	if (!healthy) FMH_LOG("HOOKS UNHEALTHY — Find My internals changed; history will not update until the tweak is updated");
	dispatch_async(gStateQ, ^{ FMHSettings.shared.hooksHealthy = healthy; });
	FMH_LOG("loaded, %ld/2 hook groups active", (long)inited);

	[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n){ onBackground(); }];
	[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n){ onBackground(); }];
}
