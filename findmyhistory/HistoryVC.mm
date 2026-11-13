// FindMyHistory — per-tag history screen: List | Map, time-window chips, export (CSV/JSON). Reads the DB read-only.
#import "FMHShared.h"
#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import <sqlite3.h>
#import "FMHData.h"

@implementation FMHRow @end

// Accuracy label: 0.1 m precision when the user opts in, else whole meters (default).
static NSString *FMHAccStr(double a) {
	if (!isfinite(a) || a < 0) return @"Accuracy unavailable";
	return FMHSettings.shared.preciseAccuracy ? [NSString stringWithFormat:@"±%.1fm", a]
	                                          : [NSString stringWithFormat:@"±%.0fm", a];
}

static NSString *FMHSourceName(NSString *source) {
	if ([source isEqualToString:@"harvesterNetwork"]) return @"Find My network";
	if ([source isEqualToString:@"ownedDeviceLocation"]) return @"Nearby device";
	if ([source isEqualToString:@"connectionEvent"]) return @"Nearby connection";
	if ([source isEqualToString:@"localReductiveFilter"]) return @"Filtered location";
	return source.length ? source : @"Unknown source";
}

static NSString *FMHLatestName(NSString *tagId) {
	sqlite3 *db; NSString *name = nil;
	if (sqlite3_open_v2([FMHDBPath() UTF8String], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) { sqlite3_close(db); return nil; }
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
	if (sqlite3_open_v2([FMHDBPath() UTF8String], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) { sqlite3_close(db); return nil; }
	sqlite3_busy_timeout(db, 2000);
	sqlite3_stmt *st;
	const char *sql = "SELECT lat,lon,h_acc,timestamp,source,battery_raw,battery_label,firmware,is_owned,created_at,tag_name,serial_number"
		" FROM locations WHERE tag_id=? AND timestamp>=? ORDER BY timestamp DESC";
	int rc = sqlite3_prepare_v2(db, sql, -1, &st, NULL);
	if (rc == SQLITE_OK) {
		sqlite3_bind_text(st, 1, [tagId UTF8String], -1, SQLITE_TRANSIENT);
		sqlite3_bind_double(st, 2, sinceEpoch);
		while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
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
	return rc == SQLITE_DONE ? out : nil;
}

@interface FMHHistoryViewController () <UITableViewDataSource, UITableViewDelegate, MKMapViewDelegate>
@property (nonatomic, copy) NSString *tagId, *name;
@property (nonatomic, strong) NSDictionary *liveMetadata;
@property (nonatomic, strong) NSArray<FMHRow*> *rows;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) MKMapView *map;
@property (nonatomic, strong) MKPointAnnotation *selectedFix;
@property (nonatomic, strong) MKCircle *accuracyCircle;
@property (nonatomic, strong) UISegmentedControl *mode, *window;
@property (nonatomic, strong) UILabel *nameLabel, *statusLabel;
@property (nonatomic, strong) UIBarButtonItem *exportItem;
@property (nonatomic, strong) NSArray<NSArray<FMHRow *> *> *dayRows;
@property (nonatomic, strong) NSArray<NSDate *> *days;
@property (nonatomic, strong) NSDateFormatter *timeFormatter, *dayFormatter;
@property (nonatomic) double windowSeconds;   // 0 = all
@property (nonatomic) BOOL healthBannerShown;
@property (nonatomic) BOOL detailsExpanded, loading, exporting, mapDirty, mapNeedsFit;
@property (nonatomic) NSUInteger loadGeneration;
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
	self.exportItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(exportTapped:)];
	UIBarButtonItem *gearItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"] style:UIBarButtonItemStylePlain target:self action:@selector(settingsTapped)];
	self.navigationItem.rightBarButtonItems = @[self.exportItem, gearItem];
	self.exportItem.accessibilityLabel = @"Export history";
	gearItem.accessibilityLabel = @"History settings";
	self.timeFormatter = [NSDateFormatter new]; self.timeFormatter.timeStyle = NSDateFormatterMediumStyle;
	self.dayFormatter = [NSDateFormatter new]; self.dayFormatter.dateStyle = NSDateFormatterFullStyle; self.dayFormatter.doesRelativeDateFormatting = YES;
	self.mapNeedsFit = YES;
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(historyChanged:) name:FMHHistoryDidChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(historyChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];

	self.nameLabel = [UILabel new]; self.nameLabel.text = self.name ?: @"AirTag History";
	self.nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
	self.nameLabel.adjustsFontForContentSizeCategory = YES; self.nameLabel.numberOfLines = 0;
	self.nameLabel.accessibilityTraits |= UIAccessibilityTraitHeader;
	self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;

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
	self.table.rowHeight = UITableViewAutomaticDimension; self.table.estimatedRowHeight = 64;
	self.table.refreshControl = [UIRefreshControl new];
	self.table.refreshControl.attributedTitle = [[NSAttributedString alloc] initWithString:@"Reload saved history"];
	[self.table.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];

	self.statusLabel = [UILabel new]; self.statusLabel.numberOfLines = 0; self.statusLabel.textAlignment = NSTextAlignmentCenter;
	self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; self.statusLabel.adjustsFontForContentSizeCategory = YES;
	self.statusLabel.textColor = UIColor.secondaryLabelColor; self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	self.statusLabel.userInteractionEnabled = NO;
	[self.view addSubview:self.nameLabel];
	[self.view addSubview:self.window];
	[self.view addSubview:self.table];
	[self.view addSubview:self.statusLabel];
	UILayoutGuide *g = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[self.nameLabel.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
		[self.nameLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:20],
		[self.nameLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-20],
		[self.window.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:12],
		[self.window.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
		[self.table.topAnchor constraintEqualToAnchor:self.window.bottomAnchor constant:8],
		[self.table.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [self.table.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
		[self.table.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
		[self.statusLabel.centerYAnchor constraintEqualToAnchor:self.table.centerYAnchor],
		[self.statusLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
		[self.statusLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
	]];
	[self reload];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)historyChanged:(NSNotification *)notification {
	if (NSThread.isMainThread) [self reload];
	else dispatch_async(dispatch_get_main_queue(), ^{ [self reload]; });
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)settingsTapped {
	FMHSettingsViewController *s = [FMHSettingsViewController new];
	[self presentViewController:[[UINavigationController alloc] initWithRootViewController:s] animated:YES completion:nil];
}

// Keep the summary scannable; backend metadata is available under Item Details.
- (UIView *)buildHeader {
	if (self.rows.count == 0 && !self.liveMetadata) return nil;
	FMHRow *latest = self.rows.firstObject;             // rows are newest-first
	double oldestTs = ((FMHRow *)self.rows.lastObject).timestamp;
	NSDateFormatter *df = [NSDateFormatter new]; df.dateStyle = NSDateFormatterShortStyle; df.timeStyle = NSDateFormatterShortStyle;
	NSString *range = [NSString stringWithFormat:@"%@ – %@", [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:oldestTs]], [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:latest.timestamp]]];
	id liveStatus = self.liveMetadata[@"battery_label"];
	NSString *battery = self.liveMetadata ? ([liveStatus isKindOfClass:NSString.class] ? liveStatus : nil) : latest.batteryLabel;
	NSString *batt = FMHBatteryTitle(battery);
	NSString *own = !latest ? @"" : latest.isOwned == 1 ? @"Owned" : (latest.isOwned == 0 ? @"Shared with you" : @"");
	NSRelativeDateTimeFormatter *relative = [NSRelativeDateTimeFormatter new];
	NSString *age = [relative localizedStringForDate:[NSDate dateWithTimeIntervalSince1970:latest.timestamp] relativeToDate:NSDate.date];
	UILabel *summary = [UILabel new]; summary.numberOfLines = 0;
	summary.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; summary.adjustsFontForContentSizeCategory = YES;
	summary.textColor = UIColor.secondaryLabelColor;
	summary.text = self.rows.count ? [NSString stringWithFormat:@"%lu fixes · Latest %@\n%@", (unsigned long)self.rows.count, age, range] : @"No saved fixes in this time range";
	UILabel *batteryText = [UILabel new]; batteryText.font = summary.font; batteryText.adjustsFontForContentSizeCategory = YES;
	batteryText.textColor = UIColor.secondaryLabelColor; batteryText.numberOfLines = 0;
	batteryText.text = [NSString stringWithFormat:@"%@ · %@", self.liveMetadata ? @"Latest battery report" : @"Last saved battery", batt];
	UIImageView *batteryIcon = [[UIImageView alloc] initWithImage:FMHBatterySymbol(battery, summary.font)];
	batteryIcon.tintColor = ([battery isEqual:@"replace"] || [battery isEqual:@"dead"]) ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
	batteryIcon.contentMode = UIViewContentModeScaleAspectFit; batteryIcon.isAccessibilityElement = NO;
	[batteryIcon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
	UIStackView *batteryRow = [[UIStackView alloc] initWithArrangedSubviews:@[batteryIcon, batteryText]];
	batteryRow.spacing = 6; batteryRow.alignment = UIStackViewAlignmentCenter;
	UIButton *details = [UIButton buttonWithType:UIButtonTypeSystem];
	details.hidden = !latest;
	[details setTitle:self.detailsExpanded ? @"Hide Item Details" : @"Item Details" forState:UIControlStateNormal];
	details.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	details.titleLabel.adjustsFontForContentSizeCategory = YES;
	details.accessibilityValue = self.detailsExpanded ? @"Expanded" : @"Collapsed";
	[details addTarget:self action:@selector(toggleDetails) forControlEvents:UIControlEventTouchUpInside];
	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[summary, batteryRow, details]];
	stack.axis = UILayoutConstraintAxisVertical; stack.alignment = UIStackViewAlignmentLeading; stack.spacing = 4;
	if (self.detailsExpanded && latest) {
		NSMutableArray *bits = [NSMutableArray arrayWithObject:@"At the latest recorded fix:"];
		if (latest.batteryLabel.length) [bits addObject:[@"Battery " stringByAppendingString:FMHBatteryTitle(latest.batteryLabel)]];
		if (latest.batteryRaw >= 0) [bits addObject:[NSString stringWithFormat:@"Legacy raw battery %lld (separate, unverified scale)", latest.batteryRaw]];
		if (latest.firmware.length) [bits addObject:[@"Firmware " stringByAppendingString:latest.firmware]];
		if (latest.serial.length) [bits addObject:[@"Serial " stringByAppendingString:latest.serial]];
		if (own.length) [bits addObject:own];
		UILabel *metadata = [UILabel new]; metadata.numberOfLines = 0;
		metadata.font = summary.font; metadata.adjustsFontForContentSizeCategory = YES; metadata.textColor = UIColor.secondaryLabelColor;
		metadata.text = [bits componentsJoinedByString:@"\n"]; [stack addArrangedSubview:metadata];
	}
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	CGFloat width = self.view.bounds.size.width;
	UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 1)];
	[h addSubview:stack];
	[NSLayoutConstraint activateConstraints:@[
		[stack.leadingAnchor constraintEqualToAnchor:h.leadingAnchor constant:20],
		[stack.trailingAnchor constraintEqualToAnchor:h.trailingAnchor constant:-20],
		[stack.topAnchor constraintEqualToAnchor:h.topAnchor constant:8], [stack.bottomAnchor constraintEqualToAnchor:h.bottomAnchor constant:-12],
	]];
	CGFloat height = [h systemLayoutSizeFittingSize:CGSizeMake(width, 0) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
	h.frame = CGRectMake(0, 0, width, ceil(height));
	return h;
}

- (void)toggleDetails { self.detailsExpanded = !self.detailsExpanded; self.table.tableHeaderView = [self buildHeader]; }

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	UIView *header = self.table.tableHeaderView;
	if (header && fabs(header.bounds.size.width - self.table.bounds.size.width) > 0.5)
		self.table.tableHeaderView = [self buildHeader];
}

- (void)reload {
	NSUInteger generation = ++self.loadGeneration;
	self.loading = YES; self.exportItem.enabled = NO;
	if (!self.rows.count) { self.statusLabel.text = @"Loading history…"; self.statusLabel.hidden = NO; }
	double since = self.windowSeconds > 0 ? [[NSDate date] timeIntervalSince1970] - self.windowSeconds : 0;
	NSString *tagId = self.tagId;
	NSString *currentName = self.name;
	FMHFetchTagMetadata(tagId, ^(NSDictionary *metadata) {
		if (generation != self.loadGeneration) return;
		self.liveMetadata = metadata;
		self.table.tableHeaderView = [self buildHeader];
	});
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{   // no DB I/O on the main thread
		NSString *name = FMHLatestName(tagId) ?: currentName;
		NSArray<FMHRow*> *rows = FMHQuery(tagId, since);
		NSMutableArray *sections = [NSMutableArray array], *days = [NSMutableArray array];
		NSCalendar *calendar = NSCalendar.currentCalendar;
		for (FMHRow *r in rows) {
			NSDate *day = [calendar startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:r.timestamp]];
			if (![day isEqual:days.lastObject]) { [days addObject:day]; [sections addObject:[NSMutableArray array]]; }
			[sections.lastObject addObject:r];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (generation != self.loadGeneration) return;
			self.loading = NO;
			self.name = name;
			self.nameLabel.text = name ?: @"AirTag History";
			self.rows = rows ?: @[]; self.dayRows = sections; self.days = days;
			self.table.tableHeaderView = [self buildHeader];
			[self.table.refreshControl endRefreshing];
			[self.table reloadData];
			self.mapDirty = YES;
			if (self.mode.selectedSegmentIndex == 1) [self rebuildMap];
			self.exportItem.enabled = rows.count > 0 && !self.exporting;
			self.statusLabel.hidden = rows.count > 0;
			self.statusLabel.text = !rows ? @"History couldn't be loaded.\nPull down in List to try again." :
				(self.windowSeconds > 0 ? @"No fixes in this time range.\nTry All to see older history." :
				 @"No history recorded yet.\nOpen Find My's Items view to receive location updates.");
			[self showHealthBannerIfNeeded];
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

- (void)modeChanged {
	BOOL mapMode = self.mode.selectedSegmentIndex == 1;
	if (mapMode && !self.map) {
		self.map = [MKMapView new]; self.map.delegate = self; self.map.translatesAutoresizingMaskIntoConstraints = NO;
		[self.view insertSubview:self.map belowSubview:self.statusLabel];
		[NSLayoutConstraint activateConstraints:@[
			[self.map.topAnchor constraintEqualToAnchor:self.table.topAnchor], [self.map.leadingAnchor constraintEqualToAnchor:self.table.leadingAnchor],
			[self.map.trailingAnchor constraintEqualToAnchor:self.table.trailingAnchor], [self.map.bottomAnchor constraintEqualToAnchor:self.table.bottomAnchor],
		]];
	}
	self.map.hidden = !mapMode; self.table.hidden = mapMode;
	if (mapMode && self.mapDirty) { self.mapNeedsFit = YES; [self rebuildMap]; }
}
- (void)windowChanged {
	switch (self.window.selectedSegmentIndex) { case 0: self.windowSeconds = 86400; break; case 1: self.windowSeconds = 7*86400; break;
		case 2: self.windowSeconds = 30*86400; break; default: self.windowSeconds = 0; }
	self.mapNeedsFit = YES; [self reload];
}

#pragma mark List
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return self.dayRows.count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.dayRows[s].count; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return [self.dayFormatter stringFromDate:self.days[s]]; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
	FMHRow *r = self.dayRows[ip.section][ip.row];
	NSDate *d = [NSDate dateWithTimeIntervalSince1970:r.timestamp];
	c.textLabel.text = [self.timeFormatter stringFromDate:d];
	c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; c.textLabel.adjustsFontForContentSizeCategory = YES;
	c.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; c.detailTextLabel.adjustsFontForContentSizeCategory = YES;
	c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", FMHSourceName(r.source), FMHAccStr(r.hAcc)];
	c.textLabel.numberOfLines = 0; c.detailTextLabel.numberOfLines = 0;
	c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; c.accessibilityHint = @"Show this fix on the map";
	return c;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[table deselectRowAtIndexPath:ip animated:YES];
	if (self.loading) return;
	FMHRow *r = self.dayRows[ip.section][ip.row];
	CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(r.lat, r.lon);
	if (!CLLocationCoordinate2DIsValid(coordinate)) return;
	self.mode.selectedSegmentIndex = 1; [self modeChanged];
	if (self.selectedFix) [self.map removeAnnotation:self.selectedFix];
	if (self.accuracyCircle) [self.map removeOverlay:self.accuracyCircle];
	MKPointAnnotation *point = [self annotationForRow:r];
	self.selectedFix = point;
	[self.map addAnnotation:point]; [self.map selectAnnotation:point animated:YES];
	self.accuracyCircle = isfinite(r.hAcc) && r.hAcc > 0 ? [MKCircle circleWithCenterCoordinate:coordinate radius:r.hAcc] : nil;
	if (self.accuracyCircle) [self.map addOverlay:self.accuracyCircle];
	double distance = isfinite(r.hAcc) && r.hAcc > 0 ? MAX(300, r.hAcc * 4) : 300;
	[self.map setRegion:MKCoordinateRegionMakeWithDistance(coordinate, distance, distance) animated:YES];
}

#pragma mark Map
- (MKPointAnnotation *)annotationForRow:(FMHRow *)r {
	MKPointAnnotation *a = [MKPointAnnotation new]; a.coordinate = CLLocationCoordinate2DMake(r.lat, r.lon);
	a.title = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:r.timestamp] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
	NSString *battery = r.batteryLabel ? [@" · Battery " stringByAppendingString:FMHBatteryTitle(r.batteryLabel)] : @"";
	a.subtitle = [NSString stringWithFormat:@"%@ · %@%@", FMHSourceName(r.source), FMHAccStr(r.hAcc), battery];
	return a;
}

- (void)rebuildMap {
	self.mapDirty = NO;
	[self.map removeAnnotations:self.map.annotations];
	[self.map removeOverlays:self.map.overlays];
	self.selectedFix = nil; self.accuracyCircle = nil;
	NSUInteger n = self.rows.count; if (n == 0) return;
	CLLocationCoordinate2D *coords = (CLLocationCoordinate2D *)malloc(sizeof(CLLocationCoordinate2D) * n);
	if (!coords) { self.statusLabel.text = @"The map couldn't be drawn. Try a shorter time range."; self.statusLabel.hidden = NO; return; }
	NSIndexSet *pinIndexes = FMHMapPinIndexes(n);
	NSMutableArray *annotations = [NSMutableArray array]; NSUInteger validCount = 0;
	// rows are newest-first; build polyline oldest->newest
	for (NSUInteger i = 0; i < n; i++) {
		FMHRow *r = self.rows[n - 1 - i];
		CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(r.lat, r.lon);
		if (!CLLocationCoordinate2DIsValid(coordinate)) continue;
		coords[validCount++] = coordinate;
		if ([pinIndexes containsIndex:i]) [annotations addObject:[self annotationForRow:r]];
	}
	if (!validCount) { free(coords); return; }
	[self.map addAnnotations:annotations];
	MKPolyline *line = [MKPolyline polylineWithCoordinates:coords count:validCount];
	double padding = 100 * MKMapPointsPerMeterAtLatitude(coords[0].latitude);
	[self.map addOverlay:line];
	free(coords);
	if (self.mapNeedsFit) {
		[self.map setVisibleMapRect:MKMapRectInset(line.boundingMapRect, -padding, -padding) edgePadding:UIEdgeInsetsMake(60,60,60,60) animated:NO];
		self.mapNeedsFit = NO;
	}
}
- (MKAnnotationView *)mapView:(MKMapView *)map viewForAnnotation:(id<MKAnnotation>)annotation {
	MKMarkerAnnotationView *view = (MKMarkerAnnotationView *)[map dequeueReusableAnnotationViewWithIdentifier:@"fix"];
	if (!view) view = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:@"fix"];
	view.annotation = annotation; view.canShowCallout = YES; return view;
}
- (MKOverlayRenderer *)mapView:(MKMapView *)mv rendererForOverlay:(id<MKOverlay>)o {
	if ([o isKindOfClass:MKCircle.class]) {
		MKCircleRenderer *circle = [[MKCircleRenderer alloc] initWithCircle:(MKCircle *)o];
		circle.fillColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.12];
		circle.strokeColor = UIColor.systemBlueColor; circle.lineWidth = 1; return circle;
	}
	if (![o isKindOfClass:[MKPolyline class]]) return [[MKOverlayRenderer alloc] initWithOverlay:o];
	MKPolylineRenderer *r = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)o];
	r.strokeColor = UIColor.systemBlueColor; r.lineWidth = 3; return r;
}

#pragma mark Export
- (void)exportTapped:(id)sender {
	if (!self.rows.count || self.loading || self.exporting) return;
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Export" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
	[ac addAction:[UIAlertAction actionWithTitle:@"CSV" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self startExport:YES]; }]];
	[ac addAction:[UIAlertAction actionWithTitle:@"JSON" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self startExport:NO]; }]];
	[ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	ac.popoverPresentationController.barButtonItem = self.exportItem;
	[self presentViewController:ac animated:YES completion:nil];
}

- (void)startExport:(BOOL)csv {
	if (self.loading || self.exporting || !self.rows.count) return;
	self.exporting = YES; self.exportItem.enabled = NO;
	NSUInteger generation = self.loadGeneration;
	NSArray<FMHRow *> *snapshot = self.rows;
	NSString *tagId = self.tagId, *name = self.name ?: @"AirTag";
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableArray *rows = [NSMutableArray arrayWithCapacity:snapshot.count]; NSString *serial = nil;
		for (FMHRow *r in snapshot) {
			if (!serial && r.serial.length) serial = r.serial;
			[rows addObject:@{@"tag_name": r.tagName ?: NSNull.null, @"serial": r.serial ?: NSNull.null,
				@"lat": @(r.lat), @"lon": @(r.lon), @"h_acc": @(r.hAcc), @"timestamp": @(r.timestamp),
				@"source": r.source ?: NSNull.null, @"battery_raw": @(r.batteryRaw), @"firmware": r.firmware ?: NSNull.null,
				@"battery_label": r.batteryLabel ?: NSNull.null,
				@"is_owned": @(r.isOwned)}];
		}
		NSError *error = nil;
		NSData *data = FMHExportData(rows, @{@"tag_id": tagId, @"tag_name": name, @"serial_number": serial ?: @""}, csv, &error);
		NSURL *directory = [[[NSFileManager defaultManager] temporaryDirectory] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
		NSURL *url = [directory URLByAppendingPathComponent:csv ? @"AirTag-history.csv" : @"AirTag-history.json"];
		if (data && [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error])
			[data writeToURL:url options:NSDataWritingAtomic error:&error];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (error || !data || generation != self.loadGeneration || !self.view.window) {
				[self removeExportDirectory:directory];
				self.exporting = NO; self.exportItem.enabled = !self.loading && self.rows.count > 0;
				if (self.view.window && (error || !data || generation != self.loadGeneration))
					[self showExportError:generation != self.loadGeneration ? @"History changed while preparing the export. Please export again." : @"The export file couldn't be created. Please try again."];
				return;
			}
			UIViewController *alert = self.presentedViewController;
			if ([alert isKindOfClass:UIAlertController.class])
				[alert dismissViewControllerAnimated:YES completion:^{ [self shareFile:url directory:directory generation:generation]; }];
			else if (!alert) [self shareFile:url directory:directory generation:generation];
			else {
				[self removeExportDirectory:directory]; self.exporting = NO;
				self.exportItem.enabled = !self.loading && self.rows.count > 0;
			}
		});
	});
}

- (void)showExportError:(NSString *)message {
	UIViewController *presented = self.presentedViewController;
	if ([presented isKindOfClass:UIAlertController.class]) {
		[presented dismissViewControllerAnimated:YES completion:^{ [self showExportError:message]; }]; return;
	}
	if (presented) return;
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't export history" message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)removeExportDirectory:(NSURL *)directory {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [[NSFileManager defaultManager] removeItemAtURL:directory error:nil]; });
}

- (void)shareFile:(NSURL *)url directory:(NSURL *)directory generation:(NSUInteger)generation {
	if (generation != self.loadGeneration || self.loading || !self.view.window || self.presentedViewController ||
		self.isBeingDismissed || self.navigationController.isBeingDismissed) {
		[self removeExportDirectory:directory]; self.exporting = NO;
		self.exportItem.enabled = !self.loading && self.rows.count > 0;
		if (generation != self.loadGeneration && self.view.window && !self.isBeingDismissed && !self.navigationController.isBeingDismissed)
			[self showExportError:@"History changed while preparing the export. Please export again."];
		return;
	}
	UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
	av.popoverPresentationController.barButtonItem = self.exportItem;
	av.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
		[self removeExportDirectory:directory];
		dispatch_async(dispatch_get_main_queue(), ^{ self.exporting = NO; self.exportItem.enabled = !self.loading && self.rows.count > 0; });
	};
	[self presentViewController:av animated:YES completion:nil];
}
@end
