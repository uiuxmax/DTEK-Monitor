#pragma once
#include "schedule_engine.h"
#include <algorithm>
#include <chrono>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

// Shared synthetic fixtures only; no OS APIs or provider requests.
namespace engine_tests {
using namespace schedule;

inline UtcInstant utc(int year, unsigned month, unsigned day, int hour, int minute = 0,
                int second = 0) {
    using namespace std::chrono;
    return UtcInstant{duration_cast<seconds>(sys_days{std::chrono::year{year}/month/day}.time_since_epoch()).count()
        + hour * 3600 + minute * 60 + second};
}

class ExplicitKyivOffset final : public KyivTimeZone {
public:
    struct Period { UtcInstant from; UtcInstant until; int offset_minutes; };
    explicit ExplicitKyivOffset(std::vector<Period> periods) : periods_(std::move(periods)) {}

    std::optional<CivilDate> local_date_at(UtcInstant instant) const override {
        using namespace std::chrono;
        for (const auto& period : periods_) {
            if (period.from <= instant && instant < period.until) {
                auto daypoint = floor<days>(sys_seconds{seconds{instant.epoch_seconds + period.offset_minutes * 60LL}});
                year_month_day date{daypoint};
                return CivilDate{int(date.year()), unsigned(date.month()), unsigned(date.day())};
            }
        }
        return std::nullopt;
    }

private:
    std::vector<Period> periods_;
};

inline const UtcInstant base = utc(2026, 1, 15, 10);
inline const ExplicitKyivOffset fixed_zone({{utc(2026, 1, 1, 0), utc(2026, 2, 1, 0), 120}});

inline Snapshot fixture() {
    Snapshot s;
    s.source = {"synthetic-provider", "https://example.invalid/synthetic"};
    s.address = {"region-1", "street-1", "house-36", "вул. Прикладна",
                 "36", "вул. Прикладна", "36", true,
                 {{"synthetic-provider", "line-a"}},
                 ScheduleIdentity{"synthetic-provider", "line-a"}, false};
    s.fetched_at_utc = base - 60;
    s.source_updated_at_utc = base - 120;
    s.days = {{CivilDate{2026, 1, 15}, TimeZoneId::europe_kyiv,
               {"synthetic-provider", "line-a"}, Applicability::explicitly_applicable,
               true, {{base + 3600, base + 7200}}}};
    return s;
}

struct Expected {
    OutcomeKind kind;
    std::optional<EventKind> event;
    std::int64_t remaining = 0;
    std::string text;
};

inline int failures = 0;
inline int checks = 0;

inline void check(const char* label, const Snapshot& s, UtcInstant now,
           const KyivTimeZone& zone, Expected expected,
           FreshnessPolicy policy = FreshnessPolicy{3600}) {
    ++checks;
    auto actual = evaluate(s, now, zone, policy);
    bool ok = actual.kind == expected.kind;
    if (expected.kind == OutcomeKind::ready) {
        ok = ok && actual.countdown && expected.event &&
             actual.countdown->event == *expected.event &&
             actual.countdown->remaining_seconds == expected.remaining &&
             actual.countdown->ukrainian_text == expected.text;
    } else ok = ok && !actual.countdown;
    std::cout << (ok ? "PASS " : "FAIL ") << label << ": "
              << outcome_name(actual.kind);
    if (actual.countdown) std::cout << "; " << actual.countdown->ukrainian_text;
    std::cout << '\n';
    if (!ok) ++failures;
}

inline void check_result(const char* label, bool ok) {
    ++checks;
    std::cout << (ok ? "PASS " : "FAIL ") << label << '\n';
    if (!ok) ++failures;
}

inline void check_freshness(const char* label, const Snapshot& s, UtcInstant now,
                     FreshnessPolicy policy, bool expected) {
    check_result(label, is_fresh(s, now, policy) == expected);
}

inline Expected ready(EventKind event, std::int64_t seconds, const char* text) {
    return {OutcomeKind::ready, event, seconds, text};
}
inline Expected denied(OutcomeKind kind) { return {kind, std::nullopt, 0, {}}; }
inline void fresh_at(Snapshot& s, UtcInstant now) {
    s.fetched_at_utc = now - 60;
    s.source_updated_at_utc = now - 120;
}

class UnavailableKyivTimeZone final : public KyivTimeZone {
public:
    std::optional<CivilDate> local_date_at(UtcInstant) const override {
        return std::nullopt;
    }
};

inline constexpr struct InvalidDateCase { const char* name; CivilDate date; } oversized_dates[] = {
        {"oversized positive year", {67562, 1, 15}},
        {"oversized negative year", {-63510, 1, 15}},
        {"oversized month", {2026, 257, 15}},
        {"oversized day", {2026, 1, 271}},
        {"maximum integer year", {std::numeric_limits<int>::max(), 1, 15}},
        {"minimum integer year", {std::numeric_limits<int>::min(), 1, 15}},
    };

void run_portable_tests();
bool run_windows_timezone_tests();
} // namespace engine_tests
