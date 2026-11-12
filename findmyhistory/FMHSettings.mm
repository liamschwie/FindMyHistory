// FindMyHistory settings store — one SQLite-backed singleton shared by the logging hooks and the in-app UI.
#import "FMHShared.h"
#import <sqlite3.h>

@implementation FMHSettings {
	NSMutableSet<NSString*> *_disabledTags;   // tags explicitly turned off
}

+ (instancetype)shared {
	static FMHSettings *s; static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [FMHSettings new]; [s load]; });
	return s;
}

- (sqlite3 *)open {
	sqlite3 *db;
	if (sqlite3_open([FMHDBPath() UTF8String], &db) != SQLITE_OK) { sqlite3_close(db); return NULL; }
	sqlite3_busy_timeout(db, 2000);
	sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);"
		"CREATE TABLE IF NOT EXISTS tag_settings(tag_id TEXT PRIMARY KEY, enabled INTEGER);", NULL, NULL, NULL);
	return db;
}

- (void)load {
	@synchronized (self) {
		_loggingEnabled = YES; _retentionDays = 90; _hooksHealthy = YES; _preciseAccuracy = NO; _disabledTags = [NSMutableSet set];
		sqlite3 *db = [self open]; if (!db) return;
		sqlite3_stmt *st;
		if (sqlite3_prepare_v2(db, "SELECT key,value FROM settings", -1, &st, NULL) == SQLITE_OK) {
			while (sqlite3_step(st) == SQLITE_ROW) {
				const char *k = (const char *)sqlite3_column_text(st, 0), *v = (const char *)sqlite3_column_text(st, 1);
				if (!k || !v) continue;
				if (!strcmp(k, "logging")) _loggingEnabled = atoi(v) != 0;
				else if (!strcmp(k, "retention")) _retentionDays = atoi(v);
				else if (!strcmp(k, "hooks_ok")) _hooksHealthy = atoi(v) != 0;
				else if (!strcmp(k, "precise_acc")) _preciseAccuracy = atoi(v) != 0;
			}
			sqlite3_finalize(st);
		}
		if (sqlite3_prepare_v2(db, "SELECT tag_id FROM tag_settings WHERE enabled=0", -1, &st, NULL) == SQLITE_OK) {
			while (sqlite3_step(st) == SQLITE_ROW) { const char *t = (const char *)sqlite3_column_text(st, 0); if (t) [_disabledTags addObject:@(t)]; }
			sqlite3_finalize(st);
		}
		sqlite3_close(db);
	}
}

// All persistence runs on this serial queue — callers (UI on main, hooks on their queue) never block on SQLite.
- (dispatch_queue_t)writeQ {
	static dispatch_queue_t q; static dispatch_once_t once;
	dispatch_once(&once, ^{ q = dispatch_queue_create("com.liam.findmyhistory.settings.write", DISPATCH_QUEUE_SERIAL); });
	return q;
}

- (void)persistKey:(NSString *)key intValue:(NSInteger)v {
	dispatch_async([self writeQ], ^{
		sqlite3 *db = [self open]; if (!db) return;
		sqlite3_stmt *st;
		if (sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", -1, &st, NULL) == SQLITE_OK) {
			sqlite3_bind_text(st, 1, [key UTF8String], -1, SQLITE_TRANSIENT);
			sqlite3_bind_text(st, 2, [[@(v) stringValue] UTF8String], -1, SQLITE_TRANSIENT);
			sqlite3_step(st); sqlite3_finalize(st);
		}
		sqlite3_close(db);
	});
}

// Setters update the in-memory value synchronously (so the logging hooks see it at once) and persist in the background.
- (void)setLoggingEnabled:(BOOL)v { @synchronized (self) { _loggingEnabled = v; } [self persistKey:@"logging" intValue:v ? 1 : 0]; }
- (void)setRetentionDays:(NSInteger)v { @synchronized (self) { _retentionDays = v; } [self persistKey:@"retention" intValue:v]; }
- (void)setHooksHealthy:(BOOL)v { @synchronized (self) { _hooksHealthy = v; } [self persistKey:@"hooks_ok" intValue:v ? 1 : 0]; }
- (void)setPreciseAccuracy:(BOOL)v {
	@synchronized (self) { _preciseAccuracy = v; } [self persistKey:@"precise_acc" intValue:v ? 1 : 0];
	[[NSNotificationCenter defaultCenter] postNotificationName:FMHHistoryDidChangeNotification object:nil];
}

- (BOOL)isTagEnabled:(NSString *)tagId {
	if (!tagId) return YES;
	@synchronized (self) { return ![_disabledTags containsObject:tagId]; }
}

- (void)setTag:(NSString *)tagId enabled:(BOOL)enabled {
	if (!tagId) return;
	@synchronized (self) { enabled ? [_disabledTags removeObject:tagId] : [_disabledTags addObject:tagId]; }
	dispatch_async([self writeQ], ^{
		sqlite3 *db = [self open]; if (!db) return;
		sqlite3_stmt *st;
		if (sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO tag_settings(tag_id,enabled) VALUES(?,?)", -1, &st, NULL) == SQLITE_OK) {
			sqlite3_bind_text(st, 1, [tagId UTF8String], -1, SQLITE_TRANSIENT);
			sqlite3_bind_int(st, 2, enabled ? 1 : 0);
			sqlite3_step(st); sqlite3_finalize(st);
		}
		sqlite3_close(db);
	});
}

@end
