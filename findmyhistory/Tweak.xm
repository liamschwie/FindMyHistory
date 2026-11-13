// FindMyHistory — logs own/shared AirTag location + battery/firmware history locally, inside Find My's sandbox.
// Phase 3: two read-only hooks verified in re/RE_NOTES.md, batched WAL SQLite, no main-thread I/O. On-device only.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sqlite3.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#import <substrate.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <ptrauth.h>
#import "FMHShared.h"
#import "FMHData.h"

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
@protocol FMHBeaconManager <NSObject>
- (void)allBeaconsOfType:(NSString *)type completion:(void (^)(NSSet *beacons))completion;
@end
static __weak id<FMHBeaconManager> gBeaconManager;
static BOOL gSnapshotInFlight;
static NSSet<NSString *> *gUIAirTagIDs; // Immutable confirmed identities; read and replaced only on the main queue.

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
static dispatch_source_t gFlushTimer;
static const NSTimeInterval kLocBufMaxAge = 120.0;   // drop buffered locations older than this
static NSArray<NSString *> *recoveryPaths(void);

// Simple-beacon raw bytes and decoded SPBeacon battery categories are separate fields.

static void openDB(void) {
	NSString *path = FMHDBPath();
	if (sqlite3_open([path UTF8String], &gDB) != SQLITE_OK) {
		FMH_LOG("open failed: %{public}s", sqlite3_errmsg(gDB)); sqlite3_close(gDB); gDB = NULL; return;
	}
	sqlite3_busy_timeout(gDB, 2000);
	int rc = sqlite3_exec(gDB, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", NULL, NULL, NULL);
	if (rc == SQLITE_OK) rc = sqlite3_exec(gDB,
		"CREATE TABLE IF NOT EXISTS locations("
		"id INTEGER PRIMARY KEY, tag_id TEXT NOT NULL, tag_name TEXT,"
		"lat REAL, lon REAL, h_acc REAL, timestamp REAL, source TEXT,"
		"battery_raw INTEGER, battery_label TEXT, firmware TEXT, is_owned INTEGER, created_at REAL, serial_number TEXT);"
		"CREATE INDEX IF NOT EXISTS idx_tag_time ON locations(tag_id, timestamp);"
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_dedup ON locations(tag_id, timestamp, lat, lon);",
		NULL, NULL, NULL);
	if (rc == SQLITE_OK) {
		sqlite3_stmt *check = NULL;
		if (sqlite3_prepare_v2(gDB, "SELECT serial_number FROM locations LIMIT 0", -1, &check, NULL) != SQLITE_OK)
			rc = sqlite3_exec(gDB, "ALTER TABLE locations ADD COLUMN serial_number TEXT", NULL, NULL, NULL);
		sqlite3_finalize(check);
	}
	if (rc != SQLITE_OK) {
		FMH_LOG("database initialization failed (%d): %{public}s", rc, sqlite3_errmsg(gDB));
		sqlite3_close(gDB); gDB = NULL; return;
	}
	if (!gMeta.count) [gMeta addEntriesFromDictionary:FMHKnownAirTags(gDB)];
	NSSet *knownIDs = [NSSet setWithArray:gMeta.allKeys];
	dispatch_async(dispatch_get_main_queue(), ^{ gUIAirTagIDs = knownIDs; });
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

static void historyChanged(void) {
	NSSet *knownIDs = [NSSet setWithArray:gMeta.allKeys];
	dispatch_async(dispatch_get_main_queue(), ^{
		gUIAirTagIDs = knownIDs;
		[[NSNotificationCenter defaultCenter] postNotificationName:FMHHistoryDidChangeNotification object:nil];
	});
}

static void scheduleFlush(void);
static void flushLocked(void) {   // call on gStateQ
	if (gFlushTimer) { dispatch_source_cancel(gFlushTimer); gFlushTimer = nil; }
	if (!gPending.count) return;
	if (!gDB) openDB();
	NSUInteger n = 0;
	int rc = FMHCommitPendingRows(gDB, gPending, &n);
	if (rc != SQLITE_OK) {
		FMH_LOG("flush failed (%d); retaining %lu pending rows for retry", rc, (unsigned long)gPending.count);
		scheduleFlush(); return;
	}
	if (n) { FMH_LOG("flushed %lu rows", (unsigned long)n); historyChanged(); }
}

static void scheduleFlush(void) {   // call on gStateQ
	if (gFlushTimer) return;
	gFlushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gStateQ);
	dispatch_source_set_timer(gFlushTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 4);
	dispatch_source_set_event_handler(gFlushTimer, ^{ flushLocked(); });
	dispatch_resume(gFlushTimer);
}

void FMHClearHistory(void (^completion)(NSError *error)) {
	dispatch_async(gStateQ, ^{
		if (!gDB) openDB();
		int rc = FMHClearPendingRows(gDB, gPending);
		if (rc == SQLITE_OK) {
			for (NSString *path in recoveryPaths()) if (![NSFileManager.defaultManager removeItemAtPath:path error:nil]) rc = SQLITE_IOERR_DELETE;
			[gLocBuf removeAllObjects];  // Pre-clear fixes awaiting metadata must not return later.
			if (gDB) sqlite3_wal_checkpoint_v2(gDB, NULL, SQLITE_CHECKPOINT_PASSIVE, NULL, NULL);
			historyChanged();
		} else FMH_LOG("clear failed (%d)", rc);
		NSError *error = rc == SQLITE_OK ? nil : [NSError errorWithDomain:@"FindMyHistory" code:rc
			userInfo:@{NSLocalizedDescriptionKey: @"History couldn't be completely cleared. Please try again."}];
		dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
	});
}

void FMHFetchTagMetadata(NSString *tagId, void (^completion)(NSDictionary *metadata)) {
	dispatch_async(gStateQ, ^{
		NSDictionary *metadata = gMeta[tagId];
		dispatch_async(dispatch_get_main_queue(), ^{ completion(metadata); });
	});
}

void FMHFetchTagList(void (^completion)(NSArray<NSDictionary *> *tags)) {
	dispatch_async(gStateQ, ^{
		NSMutableDictionary *tags = [NSMutableDictionary dictionary];
		sqlite3_stmt *st = NULL;
		if (gDB && sqlite3_prepare_v2(gDB, "SELECT tag_id,tag_name,is_owned,MAX(timestamp) FROM locations GROUP BY tag_id", -1, &st, NULL) == SQLITE_OK) {
			while (sqlite3_step(st) == SQLITE_ROW) {
				const char *uuid = (const char *)sqlite3_column_text(st, 0), *name = (const char *)sqlite3_column_text(st, 1);
				if (uuid) tags[@(uuid)] = @{@"tag_id": @(uuid), @"name": name ? @(name) : @(uuid), @"owned": @(sqlite3_column_int(st, 2))};
			}
		}
		sqlite3_finalize(st); st = NULL;
		if (gDB && sqlite3_prepare_v2(gDB, "SELECT tag_id FROM tag_settings", -1, &st, NULL) == SQLITE_OK) {
			while (sqlite3_step(st) == SQLITE_ROW) {
				const char *uuid = (const char *)sqlite3_column_text(st, 0);
				if (uuid && !tags[@(uuid)]) tags[@(uuid)] = @{@"tag_id": @(uuid), @"name": @(uuid), @"owned": @-1};
			}
		}
		sqlite3_finalize(st);
		// Live metadata is already durian-filtered and remains available even after history is cleared.
		for (NSString *uuid in gMeta) {
			id name = gMeta[uuid][@"name"]; NSString *owner = gDurianOwner[uuid];
			int owned = owner && gMeHandle ? ([owner isEqualToString:gMeHandle] ? 1 : 0) : -1;
			tags[uuid] = @{@"tag_id": uuid, @"name": [name isKindOfClass:NSString.class] ? name : uuid, @"owned": @(owned)};
		}
		NSArray *list = [tags.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
			NSComparisonResult order = [b[@"owned"] compare:a[@"owned"]];
			return order == NSOrderedSame ? [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]] : order;
		}];
		dispatch_async(dispatch_get_main_queue(), ^{ completion(list); });
	});
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
		@"battery_raw": @(batt), @"battery_label": m[@"battery_label"] ?: NSNull.null,
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
static void noteMeta(NSString *uuid, NSString *name, NSString *fw, long long batt, NSString *serial, NSString *ownerHandle, BOOL decoded) {
	if (!uuid) return;
	dispatch_async(gStateQ, ^{
		gMeta[uuid] = @{ @"name": name ?: [NSNull null], @"fw": fw ?: [NSNull null],
			@"batt": decoded ? @-1 : @(batt), @"battery_label": decoded ? (FMHBatteryCase(batt) ?: NSNull.null) : NSNull.null,
			@"serial": serial ?: [NSNull null] };
		if (ownerHandle.length) gDurianOwner[uuid] = ownerHandle;
		NSMutableArray *buf = gLocBuf[uuid];
		if (buf.count) { for (NSDictionary *loc in buf) appendRowLocked(uuid, loc, gMeta[uuid]); [gLocBuf removeObjectForKey:uuid]; }
		// backfill happens only in the end-of-batch pass (gMeHandle must be final).
	});
}

// Record a location. If the tag's metadata is known, log now; else buffer until metadata confirms it's an AirTag.
static void noteLocation(NSString *uuid, double lat, double lon, double acc, double ts, NSString *source) {
	if (!uuid || !isfinite(lat) || !isfinite(lon) || fabs(lat) > 90 || fabs(lon) > 180 || !isfinite(ts) || ts <= 0 || !isfinite(acc)) return;
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

// Verified native callback: NSSet only. Frida-created replacements are unsafe on this arm64e target.
static void refreshMetadata(void) { // main queue
	id<FMHBeaconManager> manager = gBeaconManager;
	if (!manager || gSnapshotInFlight || ![manager respondsToSelector:@selector(allBeaconsOfType:completion:)]) return;
	gSnapshotInFlight = YES;
	[manager allBeaconsOfType:@"durian" completion:^(NSSet *beacons) {
		@try {
			if ([beacons isKindOfClass:NSSet.class] || [beacons isKindOfClass:NSArray.class]) for (id raw in beacons) {
				id<FMHBeacon> b = raw;
				if (![raw respondsToSelector:@selector(type)] || ![[b type] isEqualToString:@"durian"]) continue;
				NSUUID *identifier = [b identifier];
				if (![identifier isKindOfClass:NSUUID.class]) continue;
				NSString *owner = nil;
				if ([raw respondsToSelector:@selector(owner)]) { id<FMHHandle> handle = [b owner];
					if ([handle respondsToSelector:@selector(destination)]) owner = [handle destination]; }
				noteMeta(identifier.UUIDString, [b name], [b systemVersion], [b batteryLevel], [b serialNumber], owner, YES);
			}
		} @catch (__unused NSException *e) { FMH_LOG("metadata snapshot unavailable"); }
		dispatch_async(gStateQ, ^{ historyChanged(); });
		dispatch_async(dispatch_get_main_queue(), ^{ gSnapshotInFlight = NO; });
	}];
}

static NSArray<NSString *> *recoveryPaths(void) {
	NSString *dir = [FMHDBPath() stringByDeletingLastPathComponent];
	NSMutableArray *paths = [NSMutableArray array];
	for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
		if ([name hasPrefix:@"pending-recovery-"] && [name hasSuffix:@".json"]) [paths addObject:[dir stringByAppendingPathComponent:name]];
	return paths;
}

static void recoverBufferedFixesLocked(void) {
	if (!gDB || !FMHSettings.shared.loggingEnabled) return;
	NSMutableSet *enabled = [NSMutableSet set];
	for (NSString *uuid in gMeta) if ([FMHSettings.shared isTagEnabled:uuid]) [enabled addObject:uuid];
	for (NSString *path in recoveryPaths()) {
		NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
		if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || [attrs[NSFileSize] unsignedLongLongValue] > 2 * 1024 * 1024) continue;
		NSData *data = [NSData dataWithContentsOfFile:path]; NSError *error = nil;
		id document = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
		NSArray *rows = document ? FMHRecoveryRows(document, gMeta, enabled, NSDate.date.timeIntervalSince1970, &error) : nil;
		if (!rows) { FMH_LOG("recovery validation failed; file retained"); continue; }
		NSMutableArray *batch = [rows mutableCopy]; NSUInteger inserted = 0;
		int rc = FMHCommitPendingRows(gDB, batch, &inserted);
		if (rc != SQLITE_OK) { FMH_LOG("recovery write failed (%d); file retained", rc); continue; }
		if (![NSFileManager.defaultManager removeItemAtPath:path error:&error]) FMH_LOG("recovery file retained after commit; replay is deduplicated");
		FMH_LOG("recovered %lu buffered AirTag fixes", (unsigned long)inserted);
		if (inserted) historyChanged();
	}
}

// ---- hooks (verified: re/RE_NOTES.md Phase 2 FINAL) ----

%group Snapshot
%hook SPBeaconManager
- (id)init {
	id manager = %orig;
	if (manager) { gBeaconManager = manager; dispatch_async(dispatch_get_main_queue(), ^{ refreshMetadata(); }); }
	return manager;
}
%end
%end

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
			noteMeta(uuid, name, fw, batt, serial, ownerHandle, NO);
		}
		// after the whole batch (so gMeHandle is final on the serial queue), label any still-unlabeled tags.
		dispatch_async(gStateQ, ^{ for (NSString *u in [gDurianOwner allKeys]) backfillLocked(u); });
		dispatch_async(dispatch_get_main_queue(), ^{ refreshMetadata(); });
	} @catch (__unused NSException *e) {}
	%orig;
}
%end
%end

// Force a flush on background/terminate, protected by a background-task assertion so suspension can't race it.
// ---- detail screen (UI injection + coverage #1: log the on-screen location when a tag is opened) ----

static long fmhIvarOffset(Class c, const char *n) { Ivar iv = class_getInstanceVariable(c, n); return iv ? ivar_getOffset(iv) : -1; }
static BOOL fmhIsUUID(NSString *s) { return s.length == 36 && [s characterAtIndex:8] == '-'; }
static NSString *fmhDetailTagId(UIViewController *vc);
static id fmhObjectIvar(id object, const char *name) {
	Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
	return ivar ? object_getIvar(object, ivar) : nil;
}

static UIView *fmhNativeBattery(UIView *view, Class batteryClass) {
	if ([view isKindOfClass:batteryClass]) return view;
	for (UIView *child in view.subviews) { UIView *battery = fmhNativeBattery(child, batteryClass); if (battery) return battery; }
	return nil;
}

typedef void (*FMHBatteryUpdater)(void *context __attribute__((swift_context))) __attribute__((swiftcall));
static FMHBatteryUpdater fmhBatteryUpdater(Class batteryClass) {
	static FMHBatteryUpdater update;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		Method layout = class_getInstanceMethod(batteryClass, @selector(layoutSubviews));
		Dl_info image = {0};
		if (!layout || !dladdr(ptrauth_strip((void *)method_getImplementation(layout), ptrauth_key_function_pointer), &image)) return;
		const struct mach_header_64 *header = (const struct mach_header_64 *)image.dli_fbase;
		if (!header || header->magic != MH_MAGIC_64 || header->filetype != MH_EXECUTE || header->sizeofcmds > 1024 * 1024) return;
		const uint8_t expected[] = {0x88,0x1b,0x41,0x98,0x6b,0x43,0x3e,0x14,0x9c,0x5d,0x9d,0xfc,0x77,0x92,0xe9,0xb0};
		const uint8_t *command = (const uint8_t *)(header + 1), *end = command + header->sizeofcmds;
		for (uint32_t i = 0; i < header->ncmds && command + sizeof(struct load_command) <= end; i++) {
			const struct load_command *lc = (const struct load_command *)command;
			if (lc->cmdsize < sizeof(*lc) || lc->cmdsize > (size_t)(end - command)) return;
			if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)
				&& !memcmp(((const struct uuid_command *)lc)->uuid, expected, sizeof(expected))) {
				// Native Swift fill updater, verified with 0/.15/.4/.8/1 -> widths 4/4/7.2/14.4/18 on this exact binary.
				update = (FMHBatteryUpdater)ptrauth_sign_unauthenticated((uint8_t *)image.dli_fbase + 0x403078, ptrauth_key_function_pointer, 0);
				return;
			}
			command += lc->cmdsize;
		}
	});
	return update;
}

static const char *kFMHBatteryViewKey = "fmh.battery";

static void fmhRenderBatteryHeader(UIViewController *vc, NSString *status) {
	double level = FMHBatteryFill(status);
	Class batteryClass = objc_getClass("FindMy.FMBatteryView");
	UIStackView *row = fmhObjectIvar(vc, "tertiaryRowStackView");
	if (!batteryClass || ![row isKindOfClass:UIStackView.class]) return;
	// shortcut: Apple's private Double slot is verified on 17.3.1; re-verify before enabling another OS layout.
	NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
	if (os.majorVersion != 17 || os.minorVersion != 3 || os.patchVersion != 1) return;
	FMHBatteryUpdater update = fmhBatteryUpdater(batteryClass); if (!update) return;
	Ivar value = class_getInstanceVariable(batteryClass, "level"), next = class_getInstanceVariable(batteryClass, "isLowPowerEnabled");
	if (!value || !next || ivar_getOffset(next) - ivar_getOffset(value) != sizeof(double)
		|| ivar_getOffset(value) < class_getInstanceSize(class_getSuperclass(batteryClass))
		|| ivar_getOffset(value) + sizeof(double) > class_getInstanceSize(batteryClass)) return;
	UIView *battery = objc_getAssociatedObject(vc, kFMHBatteryViewKey);
	if (!battery && level >= 0) {
		UIView *reference = fmhNativeBattery(fmhObjectIvar(vc, "batteryIndicatorView"), batteryClass);
		CGSize size = reference.bounds.size;
		if (size.width <= 0 || size.height <= 0) size = [(UIView *)fmhObjectIvar(reference, "outlineView") intrinsicContentSize];
		if (size.width <= 0 || size.height <= 0) return;
		battery = [[batteryClass alloc] initWithFrame:(CGRect){CGPointZero, size}];
		// initWithFrame creates the image views but leaves their attachment/styling to Apple's wrapper.
		for (NSString *name in @[@"outlineView", @"levelView", @"chargingView"]) {
			UIImageView *image = fmhObjectIvar(battery, name.UTF8String);
			UIImageView *original = fmhObjectIvar(reference, name.UTF8String);
			if (![image isKindOfClass:UIImageView.class] || ![original isKindOfClass:UIImageView.class] || !image.image) return;
			image.tintColor = original.tintColor;
			image.hidden = original.hidden;
			[battery addSubview:image];
		}
		battery.translatesAutoresizingMaskIntoConstraints = NO;
		NSLayoutConstraint *width = [battery.widthAnchor constraintEqualToConstant:size.width];
		NSLayoutConstraint *height = [battery.heightAnchor constraintEqualToConstant:size.height];
		width.priority = height.priority = UILayoutPriorityRequired - 1; // Let the stack collapse an unknown battery.
		[NSLayoutConstraint activateConstraints:@[width, height]];
		[battery setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
		[battery setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
		// Find My owns and repeatedly hides its stock slot; keep our indicator separate in the same native row.
		NSUInteger labelIndex = [row.arrangedSubviews indexOfObject:fmhObjectIvar(vc, "tertiaryLabel")];
		[row insertArrangedSubview:battery atIndex:labelIndex == NSNotFound ? row.arrangedSubviews.count : labelIndex + 1];
		objc_setAssociatedObject(vc, kFMHBatteryViewKey, battery, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	if (!battery) return;
	if (level >= 0) {
		memcpy((uint8_t *)(__bridge void *)battery + ivar_getOffset(value), &level, sizeof(level));
		update((__bridge void *)battery);
		battery.isAccessibilityElement = YES;
		battery.accessibilityLabel = [@"Battery: " stringByAppendingString:FMHBatteryTitle(status)];
		battery.accessibilityHint = @"Approximate category reported by Find My";
	}
	battery.hidden = level < 0;
}

static void fmhUpdateBatteryHeader(UIViewController *vc, NSString *uuid) {
	__weak UIViewController *weakVC = vc;
	FMHFetchTagMetadata(uuid, ^(NSDictionary *metadata) {
		UIViewController *vc = weakVC; if (!vc || !vc.view.window || ![fmhDetailTagId(vc) isEqual:uuid]) return;
		id status = metadata[@"battery_label"];
		fmhRenderBatteryHeader(vc, [status isKindOfClass:NSString.class] ? status : nil);
	});
}

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

static void fmh_metadataChanged(UIViewController *vc, __unused SEL selector, __unused NSNotification *notification);

static void fmhInstallHistoryButton(UIViewController *vc, NSString *uuid) {
	if (!uuid) return;
	UIButton *existing = objc_getAssociatedObject(vc, kFMHButtonKey);
	if (existing) { existing.hidden = NO; return; }
	// Use Apple's close-button renderer for the same circle, tint, and pressed appearance.
	UIButton *btn = [UIButton buttonWithType:UIButtonTypeClose];
	objc_setAssociatedObject(vc, kFMHButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightBold];
	[btn setImage:[UIImage systemImageNamed:@"clock.arrow.circlepath" withConfiguration:cfg] forState:UIControlStateNormal];
	btn.translatesAutoresizingMaskIntoConstraints = NO;
	btn.accessibilityLabel = @"History";
	__weak UIViewController *wvc = vc;
	[btn addAction:[UIAction actionWithHandler:^(__unused UIAction *a) {
		UIViewController *vc = wvc; NSString *selected = vc ? fmhDetailTagId(vc) : nil;
		if (!selected) return;
		FMHHistoryViewController *h = [[FMHHistoryViewController alloc] initWithTagId:selected name:nil];
		UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:h];
		[wvc presentViewController:nav animated:YES completion:nil];
	}] forControlEvents:UIControlEventTouchUpInside];
	[vc.view addSubview:btn];
	[vc.view bringSubviewToFront:btn];
	// Sit to the LEFT of Apple's ✕ close button (top-trailing of the card), as a separate, easy target.
	[NSLayoutConstraint activateConstraints:@[
		[btn.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-66],
		[btn.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:13],
		[btn.widthAnchor constraintEqualToConstant:30], [btn.heightAnchor constraintEqualToConstant:30],
	]];
}

static void fmh_metadataChanged(UIViewController *vc, __unused SEL selector, __unused NSNotification *notification) {
	@try {
		if (!vc.isViewLoaded || !vc.view.window) return;
		NSString *uuid = fmhDetailTagId(vc); if (!uuid) return;
		__weak UIViewController *weakVC = vc;
		FMHFetchTagMetadata(uuid, ^(NSDictionary *metadata) {
			UIViewController *vc = weakVC;
			if (!vc || !vc.view.window || ![fmhDetailTagId(vc) isEqual:uuid]) return;
			UIButton *button = objc_getAssociatedObject(vc, kFMHButtonKey); button.hidden = !metadata;
			if (metadata) { fmhInstallHistoryButton(vc, uuid); fmhUpdateBatteryHeader(vc, uuid); }
		});
	} @catch (__unused NSException *e) {}
}

static void (*orig_detailVDA)(UIViewController *, SEL, BOOL);
static void (*orig_detailVWA)(UIViewController *, SEL, BOOL);
static void fmh_detailVWA(UIViewController *vc, SEL _cmd, BOOL animated) {
	orig_detailVWA(vc, _cmd, animated);
	@try {
		NSString *uuid = fmhDetailTagId(vc);
		if (uuid && [gUIAirTagIDs containsObject:uuid]) fmhInstallHistoryButton(vc, uuid);
		else { UIButton *button = objc_getAssociatedObject(vc, kFMHButtonKey); button.hidden = YES; }
	} @catch (__unused NSException *e) {}
}

static void fmh_detailVDA(UIViewController *vc, SEL _cmd, BOOL animated) {
	orig_detailVDA(vc, _cmd, animated);
	refreshMetadata();
	[[NSNotificationCenter defaultCenter] removeObserver:vc name:FMHHistoryDidChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:vc selector:NSSelectorFromString(@"fmhMetadataDidChange:") name:FMHHistoryDidChangeNotification object:nil];
	fmh_metadataChanged(vc, NULL, nil);
}

static void onBackground(void) {
	UIApplication *app = [UIApplication sharedApplication];
	__block UIBackgroundTaskIdentifier bg = UIBackgroundTaskInvalid;
	void (^finish)(void) = ^{
		if (bg != UIBackgroundTaskInvalid) { [app endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
	};
	bg = [app beginBackgroundTaskWithName:@"fmh.flush" expirationHandler:finish];
	dispatch_async(gStateQ, ^{
		flushLocked();
		if (gDB) sqlite3_wal_checkpoint_v2(gDB, NULL, SQLITE_CHECKPOINT_PASSIVE, NULL, NULL);
		dispatch_async(dispatch_get_main_queue(), finish);
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
	dispatch_async(gStateQ, ^{ openDB(); recoverBufferedFixesLocked(); });
	Class managerClass = objc_getClass("SPBeaconManager");
	BOOL snapshotHealthy = managerClass && class_getInstanceMethod(managerClass, @selector(allBeaconsOfType:completion:));
	if (snapshotHealthy) { %init(Snapshot); } else FMH_LOG("missing AirTag metadata snapshot API");

	NSInteger inited = 0;
	if (objc_getClass("SPBeaconManagerSimpleBeaconUpdateInterface")) { %init(Meta); inited++; } else FMH_LOG("missing SPBeaconManagerSimpleBeaconUpdateInterface");
	if (objc_getClass("SPOwnerSessionLocationFetch")) { %init(Loc); inited++; } else FMH_LOG("missing SPOwnerSessionLocationFetch");

	Class detailCls = objc_getClass("FindMy.FMItemDetailContentViewController");
	if (detailCls && class_addMethod(detailCls, NSSelectorFromString(@"fmhMetadataDidChange:"), (IMP)fmh_metadataChanged, "v@:@")) {
		MSHookMessageEx(detailCls, @selector(viewWillAppear:), (IMP)fmh_detailVWA, (IMP *)&orig_detailVWA);
		MSHookMessageEx(detailCls, @selector(viewDidAppear:), (IMP)fmh_detailVDA, (IMP *)&orig_detailVDA); FMH_LOG("detail hook installed");
	}
	else FMH_LOG("missing FMItemDetailContentViewController");
	// Resilience: healthy only if BOTH classes AND their hooked selectors still exist (a renamed selector would
	// otherwise leave %init succeeding while the hook never fires).
	Class locCls = objc_getClass("SPOwnerSessionLocationFetch"), metaCls = objc_getClass("SPBeaconManagerSimpleBeaconUpdateInterface");
	BOOL healthy = (inited == 2) && snapshotHealthy
		&& locCls && class_getInstanceMethod(locCls, @selector(receivedUpdatedLocation:))
		&& metaCls && class_getInstanceMethod(metaCls, @selector(receivedSimpleBeaconUpdates:));
	if (!healthy) FMH_LOG("HOOKS UNHEALTHY — Find My internals changed; history will not update until the tweak is updated");
	dispatch_async(gStateQ, ^{ FMHSettings.shared.hooksHealthy = healthy; });
	FMH_LOG("loaded, %ld/2 hook groups active", (long)inited);

	[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n){ onBackground(); }];
	[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n){ onBackground(); }];
	[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ refreshMetadata(); }];
}
