#if !defined(DTEKMONITOR_MAC_TEST_BUILD) || !defined(__APPLE__) || (!defined(__arm64__) && !defined(__aarch64__))
#error Compile this probe through the isolated arm64 Xcode target.
#endif
#import "CoreProbeBridge.h"
#include "test_support.h"
#include "../../../tests/macos/timezone_tests.h"
#include <exception>

@implementation DMCoreProbeBridge
+ (NSDictionary<NSString *, NSNumber *> *)runTimezoneTests {
    const auto before_checks = engine_tests::checks;
    const auto before_failures = engine_tests::failures;
    try {
        const bool available = engine_tests::run_foundation_timezone_tests();
        return @{ @"checks": @(engine_tests::checks - before_checks),
                  @"failures": @(engine_tests::failures - before_failures + (available ? 0 : 1)) };
    } catch (...) {
        return @{ @"checks": @(engine_tests::checks - before_checks), @"failures": @1 };
    }
}
+ (NSDictionary<NSString *, NSNumber *> *)runPortableTests {
    try {
        engine_tests::run_portable_tests();
        return @{ @"checks": @(engine_tests::checks), @"failures": @(engine_tests::failures) };
    } catch (...) {
        return @{ @"checks": @(engine_tests::checks), @"failures": @(engine_tests::failures + 1) };
    }
}

+ (NSDictionary<NSString *, id> *)evaluateFixtureAtOffsetSeconds:(int64_t)offset {
    try {
        // All values are synthetic; this fixed-offset fixture is not a Mac
        // Europe/Kyiv adapter. The same fixture runs in portable engine tests.
        if (offset < 0 || offset > 86400) return @{ @"error": @"invalid test offset" };
        auto snapshot = engine_tests::fixture();
        const auto now = engine_tests::base + offset;
        engine_tests::fresh_at(snapshot, now);
        const auto outcome = schedule::evaluate(snapshot, now, engine_tests::fixed_zone,
                                                schedule::FreshnessPolicy{3600});
        NSString *kind = [NSString stringWithUTF8String:schedule::outcome_name(outcome.kind)];
        NSString *text = @"";
        id remaining = [NSNull null];
        if (outcome.countdown) {
            const auto& value = outcome.countdown->ukrainian_text;
            text = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
            remaining = @(outcome.countdown->remaining_seconds);
        }
        if (!kind || !text) return @{ @"error": @"invalid UTF-8 from core" };
        return @{ @"kind": kind, @"text": text, @"remainingSeconds": remaining, @"synthetic": @YES };
    } catch (const std::exception&) {
        return @{ @"error": @"C++ exception caught at bridge" };
    } catch (...) {
        return @{ @"error": @"unknown exception caught at bridge" };
    }
}
@end
