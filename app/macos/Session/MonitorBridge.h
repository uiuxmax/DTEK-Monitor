#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NSDictionary<NSString *, id> * _Nonnull (^DMGetTransport)(NSDictionary<NSString *, id> *request);

// Immutable owning result. Parsed provider bytes stay inside the native bridge.
@interface DMLookupReply : NSObject
@property(nonatomic, readonly) uint64_t token;
@property(nonatomic, readonly) NSDictionary<NSString *, id> *metadata;
@end

@interface DMLookupOperation : NSObject
- (instancetype)initWithStreet:(NSString *)street house:(NSString *)house token:(uint64_t)token suggestions:(BOOL)suggestions houseSuggestions:(BOOL)houseSuggestions
    NS_SWIFT_NAME(init(street:house:token:suggestions:houseSuggestions:));
- (instancetype)init NS_UNAVAILABLE;
- (DMLookupReply *)performWithTransport:(DMGetTransport)transport NS_SWIFT_NAME(perform(transport:));
- (void)cancel;
@end

// One state owner must serialize engine/profile access. Network work is separate.
@interface DMMonitorEngine : NSObject
- (instancetype)initWithProfile:(NSString *)profile epoch:(int64_t)epoch NS_SWIFT_NAME(init(profile:epoch:));
- (instancetype)init NS_UNAVAILABLE;
+ (nullable NSDictionary<NSString *, NSString *> *)normalizeStreet:(NSString *)street house:(NSString *)house
    NS_SWIFT_NAME(normalize(street:house:));
+ (nullable NSString *)streetQuery:(NSString *)input NS_SWIFT_NAME(streetQuery(_:));
- (NSDictionary<NSString *, id> *)snapshotAtEpoch:(int64_t)epoch NS_SWIFT_NAME(snapshot(epoch:));
- (BOOL)selectStreet:(NSString *)street house:(NSString *)house epoch:(int64_t)epoch
    NS_SWIFT_NAME(select(street:house:epoch:));
- (BOOL)acceptReply:(DMLookupReply *)reply epoch:(int64_t)epoch NS_SWIFT_NAME(accept(_:epoch:));
- (BOOL)setTheme:(NSString *)theme;
- (BOOL)setFloatingVisible:(BOOL)visible positioned:(BOOL)positioned x:(NSInteger)x y:(NSInteger)y size:(NSInteger)size
    NS_SWIFT_NAME(setFloating(visible:positioned:x:y:size:));
- (BOOL)recordEvent:(NSInteger)event status:(NSInteger)status reason:(NSInteger)reason epoch:(int64_t)epoch
    NS_SWIFT_NAME(record(event:status:reason:epoch:));
- (void)selectTomorrow:(BOOL)tomorrow;
@end
NS_ASSUME_NONNULL_END
