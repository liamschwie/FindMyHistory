#import <Foundation/Foundation.h>
#import <sqlite3.h>

// Call on the logger queue. Pending rows are removed only after a successful commit.
int FMHCommitPendingRows(sqlite3 *db, NSMutableArray<NSDictionary *> *pending, NSUInteger *inserted);
int FMHClearPendingRows(sqlite3 *db, NSMutableArray<NSDictionary *> *pending);
NSString *FMHCSVField(NSString *value);
NSData *FMHExportData(NSArray<NSDictionary *> *rows, NSDictionary *metadata, BOOL csv, NSError **error);
NSIndexSet *FMHMapPinIndexes(NSUInteger count);
// Decoded SPBeacon/FMIPItem categories; never pass the legacy simple-beacon raw byte here.
NSString *FMHBatteryCase(NSInteger status);
NSString *FMHBatteryTitle(NSString *status);
double FMHBatteryFill(NSString *status); // Apple's approximate UI fill; -1 means unavailable.
NSDictionary<NSString *, NSDictionary *> *FMHKnownAirTags(sqlite3 *db);
NSArray<NSDictionary *> *FMHRecoveryRows(id document, NSDictionary *knownTags, NSSet *enabledTags, double now, NSError **error);
