#import "FMHData.h"

NSString *FMHBatteryCase(NSInteger status) {
	return status >= 0 && status <= 6 ? @[@"unknown", @"highPower", @"fresh", @"earlyLife", @"lateLife", @"replace", @"dead"][status] : nil;
}

NSString *FMHBatteryTitle(NSString *status) {
	return @{@"highPower": @"High", @"fresh": @"Fresh", @"earlyLife": @"Good", @"lateLife": @"Getting low",
		@"replace": @"Replace battery", @"dead": @"Depleted"}[status ?: @""] ?: @"Battery unknown";
}

double FMHBatteryFill(NSString *status) {
	// Find My's FMItemBatteryStatus.level table, matched by case name (its enum order differs from FMIPCore).
	NSNumber *level = @{@"highPower": @1, @"fresh": @0.8, @"earlyLife": @0.8, @"lateLife": @0.4,
		@"replace": @0.15, @"dead": @0}[status ?: @""];
	return level ? level.doubleValue : -1;
}

NSDictionary<NSString *, NSDictionary *> *FMHKnownAirTags(sqlite3 *db) {
	NSMutableDictionary *tags = [NSMutableDictionary dictionary];
	sqlite3_stmt *st = NULL;
	const char *sql = "SELECT tag_id,tag_name,serial_number,MAX(timestamp) FROM locations GROUP BY tag_id";
	if (db && sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) while (sqlite3_step(st) == SQLITE_ROW) {
		const char *uuid = (const char *)sqlite3_column_text(st, 0), *name = (const char *)sqlite3_column_text(st, 1),
			*serial = (const char *)sqlite3_column_text(st, 2);
		if (!uuid || ![[NSUUID alloc] initWithUUIDString:@(uuid)]) continue;
		// This database contains durian-only history. Identity survives startup; old telemetry is never made current.
		tags[@(uuid)] = @{@"name": name ? @(name) : NSNull.null, @"serial": serial ? @(serial) : NSNull.null,
			@"batt": @-1, @"battery_label": NSNull.null, @"fw": NSNull.null};
	}
	sqlite3_finalize(st);
	return tags;
}

static BOOL recoveryNumber(id value, double min, double max) {
	return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
		&& isfinite([value doubleValue]) && [value doubleValue] >= min && [value doubleValue] <= max;
}

NSArray<NSDictionary *> *FMHRecoveryRows(id document, NSDictionary *knownTags, NSSet *enabledTags, double now, NSError **error) {
	NSMutableArray *rows = [NSMutableArray array];
	BOOL valid = [document isKindOfClass:NSDictionary.class]
		&& [document[@"format"] isEqual:@"FindMyHistory buffered AirTag fixes v1"]
		&& [document[@"tags"] isKindOfClass:NSDictionary.class] && [document[@"tags"] count] <= 200;
	if (valid) for (id uuid in document[@"tags"]) {
		id fixes = document[@"tags"][uuid]; NSDictionary *meta = knownTags[uuid];
		if (![uuid isKindOfClass:NSString.class] || !meta || ![fixes isKindOfClass:NSArray.class] || [fixes count] > 500) { valid = NO; break; }
		if (![enabledTags containsObject:uuid]) continue;
		for (id fix in fixes) {
			id source = [fix isKindOfClass:NSDictionary.class] ? fix[@"src"] : nil;
			valid = [fix isKindOfClass:NSDictionary.class] && recoveryNumber(fix[@"lat"], -90, 90)
				&& recoveryNumber(fix[@"lon"], -180, 180) && recoveryNumber(fix[@"acc"], -1, 1e7)
				&& recoveryNumber(fix[@"ts"], 1, now + 300)
				&& (!source || source == NSNull.null || ([source isKindOfClass:NSString.class] && [source length] <= 256));
			if (!valid || rows.count >= 5000) { valid = NO; break; }
			[rows addObject:@{@"tag_id": uuid, @"tag_name": meta[@"name"] ?: NSNull.null,
				@"lat": fix[@"lat"], @"lon": fix[@"lon"], @"h_acc": fix[@"acc"], @"timestamp": fix[@"ts"],
				@"source": source ?: NSNull.null, @"battery_raw": @-1, @"battery_label": NSNull.null,
				@"firmware": NSNull.null, @"is_owned": @-1, @"serial": meta[@"serial"] ?: NSNull.null,
				@"created_at": recoveryNumber(fix[@"rx"], 1, now + 300) ? fix[@"rx"] : @(now)}];
		}
		if (!valid) break;
	}
	if (!valid) {
		if (error) *error = [NSError errorWithDomain:@"FindMyHistory" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Buffered fixes failed validation; recovery file retained."}];
		return nil;
	}
	return rows;
}

static void bindText(sqlite3_stmt *st, int index, id value) {
	if ([value isKindOfClass:NSString.class]) sqlite3_bind_text(st, index, [value UTF8String], -1, SQLITE_TRANSIENT);
	else sqlite3_bind_null(st, index);
}

int FMHCommitPendingRows(sqlite3 *db, NSMutableArray<NSDictionary *> *pending, NSUInteger *inserted) {
	*inserted = 0;
	if (!db) return SQLITE_MISUSE;
	if (!pending.count) return SQLITE_OK;
	int rc = sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
	if (rc != SQLITE_OK) return rc;
	sqlite3_stmt *st = NULL;
	rc = sqlite3_prepare_v2(db, "INSERT INTO locations"
		"(tag_id,tag_name,lat,lon,h_acc,timestamp,source,battery_raw,battery_label,firmware,is_owned,created_at,serial_number)"
		" VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(tag_id,timestamp,lat,lon) DO NOTHING", -1, &st, NULL);
	NSUInteger n = 0;
	if (rc == SQLITE_OK) for (NSDictionary *r in pending) {
		bindText(st, 1, r[@"tag_id"]); bindText(st, 2, r[@"tag_name"]);
		sqlite3_bind_double(st, 3, [r[@"lat"] doubleValue]);
		sqlite3_bind_double(st, 4, [r[@"lon"] doubleValue]);
		sqlite3_bind_double(st, 5, [r[@"h_acc"] doubleValue]);
		sqlite3_bind_double(st, 6, [r[@"timestamp"] doubleValue]);
		bindText(st, 7, r[@"source"]);
		sqlite3_bind_int64(st, 8, [r[@"battery_raw"] longLongValue]);
		bindText(st, 9, r[@"battery_label"]); bindText(st, 10, r[@"firmware"]);
		sqlite3_bind_int(st, 11, [r[@"is_owned"] intValue]);
		sqlite3_bind_double(st, 12, [r[@"created_at"] doubleValue]);
		bindText(st, 13, r[@"serial"]);
		rc = sqlite3_step(st);
		if (rc != SQLITE_DONE) break;
		n += sqlite3_changes(db);
		rc = sqlite3_reset(st);
		if (rc != SQLITE_OK) break;
	}
	sqlite3_finalize(st);
	if (rc == SQLITE_OK) rc = sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
	if (rc != SQLITE_OK) { sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL); return rc; }
	[pending removeAllObjects]; *inserted = n;
	return SQLITE_OK;
}

int FMHClearPendingRows(sqlite3 *db, NSMutableArray<NSDictionary *> *pending) {
	if (!db) return SQLITE_MISUSE;
	int rc = sqlite3_exec(db, "DELETE FROM locations", NULL, NULL, NULL);
	if (rc == SQLITE_OK) [pending removeAllObjects];
	return rc;
}

NSString *FMHCSVField(NSString *value) {
	return [NSString stringWithFormat:@"\"%@\"", [(value ?: @"") stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

NSData *FMHExportData(NSArray<NSDictionary *> *rows, NSDictionary *metadata, BOOL csv, NSError **error) {
	NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
	formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
	NSString *(^iso)(id) = ^NSString *(id timestamp) {
		return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[timestamp doubleValue]]];
	};
	NSString *(^ownership)(id) = ^NSString *(id value) {
		int v = [value intValue]; return v == 1 ? @"owned" : (v == 0 ? @"shared" : @"unknown");
	};
	if (csv) {
		NSMutableString *text = [NSMutableString stringWithString:@"tag_id,tag_name,serial_number,time_iso,timestamp,lat,lon,h_acc,source,battery_raw,firmware,ownership,battery_status\n"];
		for (NSDictionary *r in rows) [text appendFormat:@"%@,%@,%@,%@,%.17g,%.17g,%.17g,%.17g,%@,%lld,%@,%@,%@\n",
			FMHCSVField(metadata[@"tag_id"]), FMHCSVField(r[@"tag_name"] == NSNull.null ? metadata[@"tag_name"] : r[@"tag_name"]),
			FMHCSVField(r[@"serial"] == NSNull.null ? metadata[@"serial_number"] : r[@"serial"]), FMHCSVField(iso(r[@"timestamp"])),
			[r[@"timestamp"] doubleValue], [r[@"lat"] doubleValue], [r[@"lon"] doubleValue], [r[@"h_acc"] doubleValue],
			FMHCSVField(r[@"source"] == NSNull.null ? nil : r[@"source"]), [r[@"battery_raw"] longLongValue],
			FMHCSVField(r[@"firmware"] == NSNull.null ? nil : r[@"firmware"]), FMHCSVField(ownership(r[@"is_owned"])),
			FMHCSVField([r[@"battery_label"] isKindOfClass:NSString.class] ? r[@"battery_label"] : nil)];
		return [text dataUsingEncoding:NSUTF8StringEncoding];
	}
	NSMutableArray *fixes = [NSMutableArray arrayWithCapacity:rows.count];
	for (NSDictionary *r in rows) [fixes addObject:@{@"time_iso": iso(r[@"timestamp"]), @"timestamp": r[@"timestamp"],
		@"lat": r[@"lat"], @"lon": r[@"lon"], @"h_acc": r[@"h_acc"], @"source": r[@"source"] ?: NSNull.null,
		@"battery_raw": r[@"battery_raw"], @"battery_status": r[@"battery_label"] ?: NSNull.null,
		@"firmware": r[@"firmware"] ?: NSNull.null, @"ownership": ownership(r[@"is_owned"])}];
	NSDictionary *document = @{@"tag_id": metadata[@"tag_id"] ?: NSNull.null, @"tag_name": metadata[@"tag_name"] ?: NSNull.null,
		@"serial_number": metadata[@"serial_number"] ?: NSNull.null, @"battery_scale": @"unverified raw backend status byte",
		@"battery_status_scale": @"Decoded SPBeacon category: unknown, highPower, fresh, earlyLife, lateLife, replace, dead; approximate, not percent",
		@"exported_at": [formatter stringFromDate:NSDate.date], @"fix_count": @(rows.count), @"fixes": fixes};
	return [NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingPrettyPrinted error:error];
}

NSIndexSet *FMHMapPinIndexes(NSUInteger count) {
	NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
	if (!count) return indexes;
	NSUInteger stride = MAX((count - 1) / 499 + ((count - 1) % 499 != 0), (NSUInteger)1);
	for (NSUInteger i = 0; i < count; i += stride) [indexes addIndex:i];
	[indexes addIndex:count - 1];
	return indexes;
}
