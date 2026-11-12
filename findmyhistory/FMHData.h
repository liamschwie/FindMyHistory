#import <Foundation/Foundation.h>
#import <sqlite3.h>

// Call on the logger queue. Pending rows are removed only after a successful commit.
int FMHCommitPendingRows(sqlite3 *db, NSMutableArray<NSDictionary *> *pending, NSUInteger *inserted);
int FMHClearPendingRows(sqlite3 *db, NSMutableArray<NSDictionary *> *pending);
NSString *FMHCSVField(NSString *value);
NSData *FMHExportData(NSArray<NSDictionary *> *rows, NSDictionary *metadata, BOOL csv, NSError **error);
NSIndexSet *FMHMapPinIndexes(NSUInteger count);
