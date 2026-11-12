#if !defined(DTEKMONITOR_MAC_TEST_BUILD) || !defined(__APPLE__)
#error Native timezone tests require the isolated Mac probe.
#endif
#import <Foundation/Foundation.h>
#include "timezone_tests.h"
#include "../../app/macos/Time/foundation_kyiv_timezone.h"
#include "kyiv_timezone_cases.h"

namespace engine_tests {
bool run_foundation_timezone_tests() {
    @autoreleasepool {
        const auto zone = make_foundation_kyiv_time_zone();
        if (!zone) { std::cout << "FAIL Foundation Europe/Kyiv zone unavailable\n"; return false; }
        run_kyiv_timezone_contract_tests(*zone); // Same 42 cases used by Windows.
        check_local_minute("year rollover at 24:00", {2026, 12, 31}, 1440, utc(2026, 12, 31, 22));
        check_local_minute("leap-year boundary at 24:00", {2028, 2, 28}, 1440, utc(2028, 2, 28, 22));
        check_local_minute("non-leap February 29 denied", {2027, 2, 29}, 0, std::nullopt);
        check_local_minute("ordinary minute explicit offset accepted", {2026, 10, 17}, 510, utc(2026, 10, 17, 5, 30), 180);
        check_local_minute("ordinary minute wrong offset denied", {2026, 10, 17}, 510, std::nullopt, 120);
        check_local_minute("gap with standard offset denied", {2026, 3, 29}, 210, std::nullopt, 120);
        check_local_minute("gap with daylight offset denied", {2026, 3, 29}, 210, std::nullopt, 180);
        check_local_minute("maximum offset cannot overflow", {2026, 10, 17}, 510, std::nullopt, std::numeric_limits<int>::max());
        check_local_minute("minimum offset cannot overflow", {2026, 10, 17}, 510, std::nullopt, std::numeric_limits<int>::min());
        check_local_minute("lower supported local midnight cannot underflow UTC", {1601, 1, 1}, 0, std::nullopt);
        check_result("Foundation date projection supports first UTC instant",
            zone->local_date_at(UtcInstant{-11644473600LL}) == std::optional<CivilDate>{CivilDate{1601, 1, 1}});
        check_result("Foundation date projection rejects int64 extremes",
            !zone->local_date_at(UtcInstant{std::numeric_limits<std::int64_t>::min()}) &&
            !zone->local_date_at(UtcInstant{std::numeric_limits<std::int64_t>::max()}));
        NSTimeZone *previous = NSTimeZone.defaultTimeZone;
        @try {
            for (NSString *identifier in @[@"UTC", @"America/Los_Angeles", @"Asia/Tokyo"]) {
                [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:identifier]];
                check_result("Kyiv date independent of process default zone",
                    zone->local_date_at(utc(2026, 10, 17, 21)) == std::optional<CivilDate>{CivilDate{2026, 10, 18}});
                check_local_minute("Kyiv reverse independent of process default zone", {2026, 10, 17}, 510,
                    utc(2026, 10, 17, 5, 30));
            }
        } @finally {
            [NSTimeZone setDefaultTimeZone:previous];
        }
        return true; // 42 shared + 12 boundary/offset + 6 default-zone = 60 checks.
    }
}
} // namespace engine_tests
