// Shared helpers for FindMyHistory (tweak + History UI). On-device only.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "FMHData.h"

static inline UIImage *FMHBatterySymbol(NSString *status, UIFont *font) {
	double fill = FMHBatteryFill(status);
	if (fill < 0) return nil;
	NSString *symbol = fill > 0.9 ? @"battery.100" : fill > 0.6 ? @"battery.75" : fill > 0.3 ? @"battery.50" : fill > 0 ? @"battery.25" : @"battery.0";
	return [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithFont:font]];
}

static NSString *const FMHHistoryDidChangeNotification = @"FMHHistoryDidChange";
// Completes on the main queue, after deletion and pending-buffer handling on the logger queue.
void FMHClearHistory(void (^completion)(NSError *error));
void FMHFetchTagList(void (^completion)(NSArray<NSDictionary *> *tags));
void FMHFetchTagMetadata(NSString *tagId, void (^completion)(NSDictionary *metadata));

static inline NSString *FMHDBPath(void) {
	NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/FindMyHistory"];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	return [dir stringByAppendingPathComponent:@"history.sqlite"];
}

// One logged fix.
@interface FMHRow : NSObject
@property (nonatomic) double lat, lon, hAcc, timestamp, createdAt;
@property (nonatomic, copy) NSString *source, *batteryLabel, *firmware, *tagName, *serial;
@property (nonatomic) long long batteryRaw;
@property (nonatomic) int isOwned;
@end

// Process-wide settings, persisted in the same DB (settings/tag_settings tables). The logging hooks and the UI
// are in one process (Find My), so a shared singleton is the whole story — no cross-sandbox prefs needed.
@interface FMHSettings : NSObject
+ (instancetype)shared;
@property (nonatomic) BOOL loggingEnabled;     // master switch (default YES)
@property (nonatomic) NSInteger retentionDays; // 0 = forever (default 90)
@property (nonatomic) BOOL hooksHealthy;       // NO if a Find My update broke our hook points (set by %ctor)
@property (nonatomic) BOOL preciseAccuracy;    // YES = show accuracy to 0.1 m; NO (default) = round to whole meters
- (BOOL)isTagEnabled:(NSString *)tagId;        // default YES unless explicitly disabled
- (void)setTag:(NSString *)tagId enabled:(BOOL)enabled;
@end

// A view controller that shows one tag's history (List | Map) with export. Defined in HistoryVC.mm.
@interface FMHHistoryViewController : UIViewController
- (instancetype)initWithTagId:(NSString *)tagId name:(NSString *)name;
@end

// In-app settings screen (logging master, retention, per-tag toggles, clear data). Defined in SettingsVC.mm.
@interface FMHSettingsViewController : UIViewController
@end
