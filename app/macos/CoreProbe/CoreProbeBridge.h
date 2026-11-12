#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// M1 synthetic probe only. This is not a production provider/timezone adapter.
@interface DMCoreProbeBridge : NSObject
+ (NSDictionary<NSString *, NSNumber *> *)runPortableTests;
+ (NSDictionary<NSString *, NSNumber *> *)runTimezoneTests;
+ (NSDictionary<NSString *, NSNumber *> *)runDataTests;
+ (NSDictionary<NSString *, NSNumber *> *)runDataRestartTests;
+ (NSDictionary<NSString *, NSNumber *> *)runLookupTests;
+ (NSDictionary<NSString *, id> *)evaluateFixtureAtOffsetSeconds:(int64_t)offset
    NS_SWIFT_NAME(evaluateFixture(offsetSeconds:));
@end
NS_ASSUME_NONNULL_END
