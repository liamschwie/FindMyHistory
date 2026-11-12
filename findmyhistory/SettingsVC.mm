// FindMyHistory in-app settings: master logging, retention, per-AirTag toggles, clear data. Grouped + scannable.
#import "FMHShared.h"
#import <sqlite3.h>

@interface FMHTagItem : NSObject
@property (nonatomic, copy) NSString *tagId, *name; @property (nonatomic) int isOwned;
@end
@implementation FMHTagItem @end

@interface FMHSettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<FMHTagItem*> *tags;
@property (nonatomic) BOOL clearing;
@end

@implementation FMHSettingsViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"FindMyHistory";
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
	self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
	self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	self.table.dataSource = self; self.table.delegate = self;
	[self.view addSubview:self.table];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(historyChanged:) name:FMHHistoryDidChangeNotification object:nil];
	[self reloadTags];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)historyChanged:(NSNotification *)notification { [self reloadTags]; }

- (void)reloadTags {
	FMHFetchTagList(^(NSArray<NSDictionary *> *tags) {
		NSMutableArray *items = [NSMutableArray arrayWithCapacity:tags.count];
		for (NSDictionary *tag in tags) {
			FMHTagItem *item = [FMHTagItem new]; item.tagId = tag[@"tag_id"]; item.name = tag[@"name"]; item.isOwned = [tag[@"owned"] intValue];
			[items addObject:item];
		}
		self.tags = items; [self.table reloadData];
	});
}

- (NSString *)retentionText {
	NSInteger d = FMHSettings.shared.retentionDays;
	return d <= 0 ? @"Forever" : [NSString stringWithFormat:@"%ld days", (long)d];
}

#pragma mark Table
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
	if (s == 0) return 3;               // logging + retention + precise accuracy
	if (s == 1) return MAX(self.tags.count, 1); // AirTags
	return 1;                           // clear data
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
	return s == 0 ? @"Logging" : (s == 1 ? @"AirTags" : @"Data");
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
	if (s == 1) return @"Turn off any AirTag you don't want recorded. Owned and shared tags are both supported.";
	if (s == 2) return @"All history is stored only on this device, inside Find My. Nothing is uploaded.";
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	if (ip.section == 0) {
		if (ip.row == 0) {
			c.textLabel.text = @"Enable logging";
			UISwitch *sw = [UISwitch new]; sw.on = FMHSettings.shared.loggingEnabled;
			[sw addTarget:self action:@selector(toggleLogging:) forControlEvents:UIControlEventValueChanged];
			c.accessoryView = sw; c.selectionStyle = UITableViewCellSelectionStyleNone;
		} else if (ip.row == 1) {
			c.textLabel.text = @"Keep history"; c.detailTextLabel.text = [self retentionText];
			c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		} else {
			c.textLabel.text = @"Precise accuracy";
			UISwitch *sw = [UISwitch new]; sw.on = FMHSettings.shared.preciseAccuracy;
			[sw addTarget:self action:@selector(togglePrecise:) forControlEvents:UIControlEventValueChanged];
			c.accessoryView = sw; c.selectionStyle = UITableViewCellSelectionStyleNone;
		}
	} else if (ip.section == 1) {
		if (self.tags.count == 0) { c.textLabel.text = @"No AirTags recorded yet"; c.textLabel.textColor = UIColor.secondaryLabelColor; c.selectionStyle = UITableViewCellSelectionStyleNone; return c; }
		FMHTagItem *t = self.tags[ip.row];
		c.textLabel.text = t.name;
		c.detailTextLabel.text = t.isOwned == 1 ? @"owned" : (t.isOwned == 0 ? @"shared" : @"");
		UISwitch *sw = [UISwitch new]; sw.on = [FMHSettings.shared isTagEnabled:t.tagId];
		NSString *tagId = t.tagId;
		[sw addAction:[UIAction actionWithHandler:^(UIAction *action) {
			[FMHSettings.shared setTag:tagId enabled:((UISwitch *)action.sender).on];
		}] forControlEvents:UIControlEventValueChanged];
		c.accessoryView = sw; c.selectionStyle = UITableViewCellSelectionStyleNone;
	} else {
		c.textLabel.text = @"Clear all history"; c.textLabel.textColor = UIColor.systemRedColor;
		c.textLabel.textAlignment = NSTextAlignmentCenter;
	}
	return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];
	if (ip.section == 0 && ip.row == 1) [self pickRetention];
	else if (ip.section == 2) [self confirmClear];
}

- (void)toggleLogging:(UISwitch *)sw { FMHSettings.shared.loggingEnabled = sw.on; }
- (void)togglePrecise:(UISwitch *)sw { FMHSettings.shared.preciseAccuracy = sw.on; }

- (void)pickRetention {
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Keep history" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
	NSArray *opts = @[@30, @90, @180, @365, @0];
	for (NSNumber *d in opts) {
		NSString *title = d.integerValue <= 0 ? @"Forever" : [NSString stringWithFormat:@"%@ days", d];
		[ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
			FMHSettings.shared.retentionDays = d.integerValue; [self.table reloadData];
		}]];
	}
	[ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	ac.popoverPresentationController.sourceView = self.table;
	[self presentViewController:ac animated:YES completion:nil];
}

- (void)confirmClear {
	if (self.clearing) return;
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Clear all history?" message:@"This permanently deletes every recorded location for all AirTags. This cannot be undone." preferredStyle:UIAlertControllerStyleAlert];
	[ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[ac addAction:[UIAlertAction actionWithTitle:@"Delete All" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
		self.clearing = YES;
		FMHClearHistory(^(NSError *error) {
			self.clearing = NO;
			if (error) {
				UIAlertController *failure = [UIAlertController alertControllerWithTitle:@"Couldn't clear history" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
				[failure addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
				[self presentViewController:failure animated:YES completion:nil];
			} else [self reloadTags];
		});
	}]];
	[self presentViewController:ac animated:YES completion:nil];
}
@end
