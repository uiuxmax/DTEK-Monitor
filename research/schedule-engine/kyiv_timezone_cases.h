#pragma once

#include "test_support.h"
#include "kyiv_time_projection.h"

namespace engine_tests {
namespace {
void check_date(const char* label, const KyivTimeZone& zone, UtcInstant instant,
                std::optional<CivilDate> expected) {
    ++checks;
    const auto actual = zone.local_date_at(instant);
    const bool ok = actual == expected;
    std::cout << (ok ? "PASS " : "FAIL ") << label << '\n';
    if (!ok) ++failures;
}

void check_local_minute(const char* label, CivilDate date, unsigned minute,
                        std::optional<UtcInstant> expected,
                        std::optional<int> utc_offset_minutes = std::nullopt) {
    ++checks;
    const auto actual = kyiv_utc_at_local_minute(date, minute, utc_offset_minutes);
    const bool ok = actual == expected;
    std::cout << (ok ? "PASS " : "FAIL ") << label << '\n';
    if (!ok) ++failures;
}

bool projected_minute_is(UtcInstant instant, CivilDate date, unsigned minute) {
    const auto local = kyiv_local_minute_at(instant);
    return local && local->date == date && local->minute == minute;
}
} // namespace

inline bool run_kyiv_timezone_contract_tests(const KyivTimeZone& named_zone) {
    auto s = fixture();
    // These UTC instants straddle local midnights on both sides of the 2026
    // seasonal changes. They catch a fixed +02:00 or +03:00 implementation.
    check_date("40 spring before midnight, standard time", named_zone,
               utc(2026, 3, 28, 21, 59), CivilDate{2026, 3, 28});
    check_date("41 spring midnight, standard time", named_zone,
               utc(2026, 3, 28, 22), CivilDate{2026, 3, 29});
    check_date("42 spring before midnight, daylight time", named_zone,
               utc(2026, 3, 29, 20, 59), CivilDate{2026, 3, 29});
    check_date("43 spring midnight, daylight time", named_zone,
               utc(2026, 3, 29, 21), CivilDate{2026, 3, 30});
    check_date("44 autumn before midnight, daylight time", named_zone,
               utc(2026, 10, 24, 20, 59), CivilDate{2026, 10, 24});
    check_date("45 autumn midnight, daylight time", named_zone,
               utc(2026, 10, 24, 21), CivilDate{2026, 10, 25});
    check_date("46 autumn before midnight, standard time", named_zone,
               utc(2026, 10, 25, 21, 59), CivilDate{2026, 10, 25});
    check_date("47 autumn midnight, standard time", named_zone,
               utc(2026, 10, 25, 22), CivilDate{2026, 10, 26});
    check_date("48 out-of-range UTC fails closed", named_zone,
               UtcInstant{253402300800LL}, std::nullopt);
    s = fixture();
    check("49 real Kyiv adapter with synthetic interval", s, base, named_zone,
          ready(EventKind::outage_starts, 3600, "Відключення через 1 г"));

    // Fixed Kyiv/UTC conversion vectors. No provider JSON is consumed.
    check_local_minute("51 sample 08:30 Kyiv", {2026, 10, 17}, 510,
                       utc(2026, 10, 17, 5, 30));
    check_local_minute("52 sample 12:00 Kyiv", {2026, 10, 17}, 720,
                       utc(2026, 10, 17, 9));
    check_local_minute("53 sample 17:30 Kyiv", {2026, 10, 17}, 1050,
                       utc(2026, 10, 17, 14, 30));
    check_local_minute("54 sample 21:00 Kyiv", {2026, 10, 17}, 1260,
                       utc(2026, 10, 17, 18));
    check_local_minute("55 local midnight", {2026, 10, 17}, 0,
                       utc(2026, 10, 16, 21));
    check_local_minute("56 end-of-day boundary", {2026, 10, 17}, 1440,
                       utc(2026, 10, 17, 21));
    check_local_minute("57 spring skipped minute denied", {2026, 3, 29}, 210,
                       std::nullopt);
    check_local_minute("58 autumn repeated minute denied", {2026, 10, 25}, 210,
                       std::nullopt);
    check_local_minute("59 autumn before repeated hour", {2026, 10, 25}, 150,
                       utc(2026, 10, 24, 23, 30));
    check_local_minute("60 autumn after repeated hour", {2026, 10, 25}, 270,
                       utc(2026, 10, 25, 2, 30));
    check_local_minute("61 minute past day denied", {2026, 10, 17}, 1441,
                       std::nullopt);
    check_local_minute("62 invalid date denied", {2026, 2, 30}, 510,
                       std::nullopt);
    check_local_minute("63 autumn daylight offset selects first 03:30", {2026, 10, 25}, 210,
                       utc(2026, 10, 25, 0, 30), 180);
    check_local_minute("64 autumn standard offset selects second 03:30", {2026, 10, 25}, 210,
                       utc(2026, 10, 25, 1, 30), 120);

    check_result("UTC sample start projects to exact 08:30 Kyiv",
                 projected_minute_is(utc(2026, 10, 17, 5, 30), {2026, 10, 17}, 510));
    check_result("UTC sample end projects to exact 12:00 Kyiv",
                 projected_minute_is(utc(2026, 10, 17, 9), {2026, 10, 17}, 720));
    check_result("UTC next midnight projects to next date minute zero",
                 projected_minute_is(utc(2026, 10, 17, 21), {2026, 10, 18}, 0));
    check_result("UTC projection carries the new Kyiv date after midnight",
                 projected_minute_is(utc(2026, 10, 17, 23, 30), {2026, 10, 18}, 150));
    check_result("UTC projection rejects subminute boundaries without rounding",
                 !kyiv_local_minute_at(utc(2026, 10, 17, 5, 30, 1)) &&
                 !kyiv_local_minute_at(UtcInstant{-1}));
    check_result("UTC projection accepts exact spring transition boundaries",
                 projected_minute_is(utc(2026, 3, 29, 0, 59), {2026, 3, 29}, 179) &&
                 projected_minute_is(utc(2026, 3, 29, 1), {2026, 3, 29}, 240));
    check_result("UTC projection rejects both occurrences of repeated autumn minute",
                 !kyiv_local_minute_at(utc(2026, 10, 25, 0, 30)) &&
                 !kyiv_local_minute_at(utc(2026, 10, 25, 1, 30)));
    check_result("UTC projection rejects instants outside Windows range",
                 !kyiv_local_minute_at(UtcInstant{-11644473660LL}) &&
                 !kyiv_local_minute_at(UtcInstant{253402300800LL}) &&
                 !kyiv_local_minute_at(UtcInstant{std::numeric_limits<std::int64_t>::min()}) &&
                 !kyiv_local_minute_at(UtcInstant{std::numeric_limits<std::int64_t>::max()}));

    for (const auto& invalid : oversized_dates) {
        const std::string adapter_label = std::string("Kyiv rejects ") + invalid.name;
        check_local_minute(adapter_label.c_str(), invalid.date, 720, std::nullopt);
    }
    check_local_minute("Kyiv rejects year below Windows range", {1600, 1, 15}, 720,
                       std::nullopt);
    check_local_minute("Kyiv rejects year above Windows range", {10000, 1, 15}, 720,
                       std::nullopt);
    check_local_minute("Kyiv upper supported year does not overflow minute arithmetic",
                       {9999, 1, 15}, 720, utc(9999, 1, 15, 10));
    check_local_minute("Kyiv end boundary cannot wrap beyond supported years",
                       {9999, 12, 31}, 1440, std::nullopt);

    return true;
}
} // namespace engine_tests
