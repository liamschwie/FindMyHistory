// FindMyHistory — per-tag history screen: List | Map, time-window chips, export (CSV/JSON). Reads the DB read-only.
#import "FMHShared.h"
#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import <sqlite3.h>

@implementation FMHRow @end

// Accuracy label: 0.1 m precision when the user opts in, else whole meters (default).
static NSString *FMHAccStr(double a) {
	return FMHSettings.shared.preciseAccuracy ? [NSString stringWithFormat:@"±%.1fm", a]
	                                          : [NSString stringWithFormat:@"±%.0fm", a];
}

static NSString *FMHLatestName(NSString *tagId) {
	sqlite3 *db; NSString *name = nil;
	if (sqlite3_open_v2([FMHDBPath() UTF8String], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return nil;
	sqlite3_stmt *st;
	if (sqlite3_prepare_v2(db, "SELECT tag_name FROM locations WHERE tag_id=? AND tag_name IS NOT NULL ORDER BY timestamp DESC LIMIT 1", -1, &st, NULL) == SQLITE_OK) {
		sqlite3_bind_text(st, 1, [tagId UTF8String], -1, SQLITE_TRANSIENT);
		if (sqlite3_step(st) == SQLITE_ROW) { const char *s = (const char *)sqlite3_column_text(st, 0); if (s) name = @(s); }
		sqlite3_finalize(st);
	}
	sqlite3_close(db);
	return name;
}

static NSArray<FMHRow*> *FMHQuery(NSString *tagId, double sinceEpoch) {
	NSMutableArray *out = [NSMutableArray array];
	sqlite3 *db;
	if (sqlite3_open_v2([FMHDBPath() UTF8String], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return out;
	sqlite3_stmt *st;
	const char *sql = "SELECT lat,lon,h_acc,timestamp,source,battery_raw,battery_label,firmware,is_owned,created_at,tag_name,serial_number"
		" FROM locations WHERE tag_id=? AND timestamp>=? ORDER BY timestamp DESC";
	if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
		sqlite3_bind_text(st, 1, [tagId UTF8String], -1, SQLITE_TRANSIENT);
		sqlite3_bind_double(st, 2, sinceEpoch);
		while (sqlite3_step(st) == SQLITE_ROW) {
			FMHRow *r = [FMHRow new];
			r.lat = sqlite3_column_double(st, 0); r.lon = sqlite3_column_double(st, 1); r.hAcc = sqlite3_column_double(st, 2);
			r.timestamp = sqlite3_column_double(st, 3);
			const char *s = (const char *)sqlite3_column_text(st, 4); r.source = s ? @(s) : nil;
			r.batteryRaw = sqlite3_column_int64(st, 5);
			const char *bl = (const char *)sqlite3_column_text(st, 6); r.batteryLabel = bl ? @(bl) : nil;
			const char *fw = (const char *)sqlite3_column_text(st, 7); r.firmware = fw ? @(fw) : nil;
			r.isOwned = sqlite3_column_int(st, 8); r.createdAt = sqlite3_column_double(st, 9);
			const char *nm = (const char *)sqlite3_column_text(st, 10); r.tagName = nm ? @(nm) : nil;
			const char *sn = (const char *)sqlite3_column_text(st, 11); r.serial = sn ? @(sn) : nil;
			[out addObject:r];
		}
		sqlite3_finalize(st);
	}
	sqlite3_close(db);
	return out;
}

@interface FMHHistoryViewController () <UITableViewDataSource, UITableViewDelegate, MKMapViewDelegate>
@property (nonatomic, copy) NSString *tagId, *name;
@property (nonatomic, strong) NSArray<FMHRow*> *rows;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) MKMapView *map;
@property (nonatomic, strong) UISegmentedControl *mode, *window;
@property (nonatomic) double windowSeconds;   // 0 = all
@property (nonatomic) BOOL healthBannerShown;
@end

@implementation FMHHistoryViewController

- (instancetype)initWithTagId:(NSString *)tagId name:(NSString *)name {
	if ((self = [super init])) { _tagId = [tagId copy]; _name = [name copy]; _windowSeconds = 0; }
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = self.name ?: @"History";
	self.view.backgroundColor = UIColor.systemBackgroundColor;
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissSelf)];
	UIBarButtonItem *exportItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(exportTapped:)];
	UIBarButtonItem *gearItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"] style:UIBarButtonItemStylePlain target:self action:@selector(settingsTapped)];
	self.navigationItem.rightBarButtonItems = @[exportItem, gearItem];

	self.mode = [[UISegmentedControl alloc] initWithItems:@[@"List", @"Map"]];
	self.mode.selectedSegmentIndex = 0;
	[self.mode addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
	self.navigationItem.titleView = self.mode;

	self.window = [[UISegmentedControl alloc] initWithItems:@[@"24h", @"7d", @"30d", @"All"]];
	self.window.selectedSegmentIndex = 3;
	[self.window addTarget:self action:@selector(windowChanged) forControlEvents:UIControlEventValueChanged];
	self.window.translatesAutoresizingMaskIntoConstraints = NO;

	self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
	self.table.dataSource = self; self.table.delegate = self;
	self.table.translatesAutoresizingMaskIntoConstraints = NO;

	self.map = [[MKMapView alloc] init];
	self.map.delegate = self; self.map.hidden = YES;
	self.map.translatesAutoresizingMaskIntoConstraints = NO;

	[self.view addSubview:self.window];
	[self.view addSubview:self.table];
	[self.view addSubview:self.map];
	UILayoutGuide *g = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[self.window.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
		[self.window.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
		[self.table.topAnchor constraintEqualToAnchor:self.window.bottomAnchor constant:8],
		[self.table.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [self.table.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
		[self.table.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
		[self.map.topAnchor constraintEqualToAnchor:self.table.topAnchor], [self.map.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
		[self.map.trailingAnchor constraintEqualToAnchor:g.trailingAnchor], [self.map.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
	]];
	[self reload];
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)settingsTapped {
	FMHSettingsViewController *s = [FMHSettingsViewController new];
	[self presentViewController:[[UINavigationController alloc] initWithRootViewController:s] animated:YES completion:nil];
}

// Stats header: current battery (raw+approx), firmware, serial, ownership, fix count, date range.
- (UIView *)buildHeader {
	if (self.rows.count == 0) return nil;
	FMHRow *latest = self.rows.firstObject;             // rows are newest-first
	double oldestTs = ((FMHRow *)self.rows.lastObject).timestamp;
	NSDateFormatter *df = [NSDateFormatter new]; df.dateStyle = NSDateFormatterShortStyle; df.timeStyle = NSDateFormatterShortStyle;
	NSString *range = [NSString stringWithFormat:@"%@ – %@", [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:oldestTs]], [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:latest.timestamp]]];
	NSString *batt = latest.batteryRaw >= 0 ? [NSString stringWithFormat:@"Battery raw %lld (scale unverified)", latest.batteryRaw] : @"Battery unknown";
	NSString *own = latest.isOwned == 1 ? @"Owned" : (latest.isOwned == 0 ? @"Shared with you" : @"");
	NSMutableArray *bits = [NSMutableArray array];
	[bits addObject:batt];
	if (latest.firmware.length) [bits addObject:[@"Firmware " stringByAppendingString:latest.firmware]];
	if (latest.serial.length) [bits addObject:[@"Serial " stringByAppendingString:latest.serial]];
	if (own.length) [bits addObject:own];
	[bits addObject:[NSString stringWithFormat:@"%lu fixes · %@", (unsigned long)self.rows.count, range]];

	UILabel *l = [UILabel new];
	l.numberOfLines = 0; l.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	l.textColor = UIColor.secondaryLabelColor; l.text = [bits componentsJoinedByString:@"\n"];
	l.translatesAutoresizingMaskIntoConstraints = NO;
	UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 1)];
	[h addSubview:l];
	[NSLayoutConstraint activateConstraints:@[
		[l.leadingAnchor constraintEqualToAnchor:h.layoutMarginsGuide.leadingAnchor],
		[l.trailingAnchor constraintEqualToAnchor:h.layoutMarginsGuide.trailingAnchor],
		[l.topAnchor constraintEqualToAnchor:h.topAnchor constant:8], [l.bottomAnchor constraintEqualToAnchor:h.bottomAnchor constant:-8],
	]];
	CGFloat height = [l systemLayoutSizeFittingSize:CGSizeMake(self.view.bounds.size.width - 40, 0) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height + 16;
	h.frame = CGRectMake(0, 0, self.view.bounds.size.width, height);
	return h;
}

- (void)reload {
	double since = self.windowSeconds > 0 ? [[NSDate date] timeIntervalSince1970] - self.windowSeconds : 0;
	NSString *tagId = self.tagId;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{   // no DB I/O on the main thread
		NSString *name = self.name ?: FMHLatestName(tagId);
		NSArray<FMHRow*> *rows = FMHQuery(tagId, since);
		dispatch_async(dispatch_get_main_queue(), ^{
			self.name = name;
			self.rows = rows;
			self.table.tableHeaderView = [self buildHeader];
			[self.table reloadData];
			[self rebuildMap];
			[self showHealthBannerIfNeeded];
			if (rows.count == 0) self.title = [NSString stringWithFormat:@"%@ (no history yet)", name ?: @"History"];
			else self.title = [NSString stringWithFormat:@"%@ · %lu", name ?: @"History", (unsigned long)rows.count];
		});
	});
}

- (void)showHealthBannerIfNeeded {
	if (FMHSettings.shared.hooksHealthy || self.healthBannerShown) return;   // fail loud, not silent, and only once
	self.healthBannerShown = YES;
	UILabel *l = [UILabel new];
	l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter;
	l.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	l.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.15]; l.textColor = UIColor.systemRedColor;
	l.text = @"⚠︎ FindMyHistory needs an update — Find My changed and new locations aren't being recorded.";
	l.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:l];
	[NSLayoutConstraint activateConstraints:@[
		[l.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [l.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[l.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
	]];
}

- (void)modeChanged { BOOL mapMode = self.mode.selectedSegmentIndex == 1; self.map.hidden = !mapMode; self.table.hidden = mapMode; }
- (void)windowChanged {
	switch (self.window.selectedSegmentIndex) { case 0: self.windowSeconds = 86400; break; case 1: self.windowSeconds = 7*86400; break;
		case 2: self.windowSeconds = 30*86400; break; default: self.windowSeconds = 0; }
	[self reload];
}

#pragma mark List
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.rows.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
	FMHRow *r = self.rows[ip.row];
	NSDate *d = [NSDate dateWithTimeIntervalSince1970:r.timestamp];
	NSDateFormatter *df = [NSDateFormatter new]; df.dateStyle = NSDateFormatterMediumStyle; df.timeStyle = NSDateFormatterShortStyle;
	c.textLabel.text = [df stringFromDate:d];
	NSString *batt = r.batteryRaw >= 0 ? [NSString stringWithFormat:@" · batt raw %lld", r.batteryRaw] : @"";
	NSString *own = r.isOwned == 1 ? @" · owned" : (r.isOwned == 0 ? @" · shared" : @"");
	c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@%@%@", FMHAccStr(r.hAcc), r.source ?: @"?", batt, own];
	c.detailTextLabel.numberOfLines = 2;
	return c;
}

#pragma mark Map
- (void)rebuildMap {
	[self.map removeAnnotations:self.map.annotations];
	[self.map removeOverlays:self.map.overlays];
	NSUInteger n = self.rows.count; if (n == 0) return;
	CLLocationCoordinate2D *coords = (CLLocationCoordinate2D *)malloc(sizeof(CLLocationCoordinate2D) * n);
	// rows are newest-first; build polyline oldest->newest
	for (NSUInteger i = 0; i < n; i++) {
		FMHRow *r = self.rows[n - 1 - i];
		coords[i] = CLLocationCoordinate2DMake(r.lat, r.lon);
		MKPointAnnotation *a = [MKPointAnnotation new]; a.coordinate = coords[i];
		NSDate *d = [NSDate dateWithTimeIntervalSince1970:r.timestamp];
		a.title = [NSDateFormatter localizedStringFromDate:d dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
		a.subtitle = [NSString stringWithFormat:@"%@ · %@", FMHAccStr(r.hAcc), r.source ?: @"?"];
		[self.map addAnnotation:a];
	}
	MKPolyline *line = [MKPolyline polylineWithCoordinates:coords count:n];
	[self.map addOverlay:line];
	self.map.visibleMapRect = line.boundingMapRect; free(coords);
	[self.map setVisibleMapRect:line.boundingMapRect edgePadding:UIEdgeInsetsMake(60,60,60,60) animated:NO];
}
- (MKOverlayRenderer *)mapView:(MKMapView *)mv rendererForOverlay:(id<MKOverlay>)o {
	if (![o isKindOfClass:[MKPolyline class]]) return [[MKOverlayRenderer alloc] initWithOverlay:o];
	MKPolylineRenderer *r = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)o];
	r.strokeColor = UIColor.systemBlueColor; r.lineWidth = 3; return r;
}

#pragma mark Export
- (void)exportTapped:(id)sender {
	if (self.rows.count == 0) return;
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Export" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
	[ac addAction:[UIAlertAction actionWithTitle:@"CSV" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self shareFile:[self writeExport:YES]]; }]];
	[ac addAction:[UIAlertAction actionWithTitle:@"JSON" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self shareFile:[self writeExport:NO]]; }]];
	[ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
	[self presentViewController:ac animated:YES completion:nil];
}
- (NSString *)ownedStr:(int)v { return v == 1 ? @"owned" : (v == 0 ? @"shared" : @"unknown"); }
- (NSString *)isoTime:(double)ts {
	NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
	return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}
- (NSURL *)writeExport:(BOOL)csv {
	NSMutableString *s = [NSMutableString string];
	NSString *serial = nil; for (FMHRow *r in self.rows) if (r.serial.length) { serial = r.serial; break; }
	if (csv) {
		[s appendString:@"tag_id,tag_name,serial_number,time_iso,timestamp,lat,lon,h_acc,source,battery_raw,firmware,ownership\n"];
		for (FMHRow *r in self.rows)
			[s appendFormat:@"%@,%@,%@,%@,%.0f,%.6f,%.6f,%.0f,%@,%lld,%@,%@\n", self.tagId, r.tagName ?: self.name ?: @"",
				r.serial ?: serial ?: @"", [self isoTime:r.timestamp], r.timestamp, r.lat, r.lon, r.hAcc, r.source ?: @"",
				r.batteryRaw, r.firmware ?: @"", [self ownedStr:r.isOwned]];
	} else {
		NSMutableArray *arr = [NSMutableArray array];
		for (FMHRow *r in self.rows) [arr addObject:@{ @"time_iso": [self isoTime:r.timestamp], @"timestamp": @(r.timestamp),
			@"lat": @(r.lat), @"lon": @(r.lon), @"h_acc": @(r.hAcc), @"source": r.source ?: NSNull.null,
			@"battery_raw": @(r.batteryRaw), @"firmware": r.firmware ?: NSNull.null, @"ownership": [self ownedStr:r.isOwned] }];
		NSDictionary *doc = @{ @"tag_id": self.tagId ?: NSNull.null, @"tag_name": self.name ?: NSNull.null,
			@"serial_number": serial ?: NSNull.null, @"battery_scale": @"unverified raw backend status byte",
			@"exported_at": [self isoTime:[[NSDate date] timeIntervalSince1970]],
			@"fix_count": @(self.rows.count), @"fixes": arr };
		NSData *d = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:nil];
		[s appendString:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]];
	}
	NSString *safe = [(self.name ?: @"airtag") stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
	NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-history.%@", safe, csv ? @"csv" : @"json"]];
	[s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
	return [NSURL fileURLWithPath:path];
}
- (void)shareFile:(NSURL *)url {
	UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
	av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
	[self presentViewController:av animated:YES completion:nil];
}
@end
