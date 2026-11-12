#import <Foundation/Foundation.h>
#include "foundation_kyiv_timezone.h"

#include <chrono>
#include <cmath>
#include <initializer_list>
#include <memory>

namespace schedule {
namespace {
constexpr std::int64_t first_utc = -11644473600LL;
constexpr std::int64_t last_utc = 253402300799LL;
constexpr NSCalendarUnit components = NSCalendarUnitEra | NSCalendarUnitYear |
    NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour |
    NSCalendarUnitMinute | NSCalendarUnitSecond;

bool supported(UtcInstant value) {
    return value.epoch_seconds >= first_utc && value.epoch_seconds <= last_utc;
}

bool valid_date(CivilDate value) {
    if (value.year < 1601 || value.year > 9999 || value.month < 1 || value.month > 12 ||
        value.day < 1 || value.day > 31) return false;
    using namespace std::chrono;
    return year_month_day{year{value.year}, month{value.month}, day{value.day}}.ok();
}

NSCalendar *kyiv_calendar() {
    NSTimeZone *zone = [NSTimeZone timeZoneWithName:@"Europe/Kyiv"];
    if (!zone) return nil;
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = zone;
    calendar.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    return calendar;
}

std::optional<CivilDate> civil_date(NSDateComponents *value) {
    if (!value || value.era != 1 || value.year < 1601 || value.year > 9999 ||
        value.month < 1 || value.month > 12 || value.day < 1 || value.day > 31) return std::nullopt;
    const CivilDate result{static_cast<int>(value.year), static_cast<unsigned>(value.month),
                           static_cast<unsigned>(value.day)};
    return valid_date(result) ? std::optional<CivilDate>{result} : std::nullopt;
}

bool same_minute(NSDateComponents *a, NSDateComponents *b) {
    return a && b && a.era == b.era && a.year == b.year && a.month == b.month &&
        a.day == b.day && a.hour == b.hour && a.minute == b.minute && a.second == b.second;
}

class FoundationKyivTimeZone final : public KyivTimeZone {
public:
    std::optional<CivilDate> local_date_at(UtcInstant instant) const override {
        @autoreleasepool {
            if (!supported(instant)) return std::nullopt;
            NSCalendar *calendar = kyiv_calendar();
            if (!calendar) return std::nullopt;
            NSDate *point = [NSDate dateWithTimeIntervalSince1970:static_cast<double>(instant.epoch_seconds)];
            return civil_date([calendar components:components fromDate:point]);
        }
    }
};
} // namespace

std::unique_ptr<KyivTimeZone> make_foundation_kyiv_time_zone() {
    @autoreleasepool {
        if (!kyiv_calendar()) return nullptr;
        return std::make_unique<FoundationKyivTimeZone>();
    }
}

std::optional<UtcInstant> kyiv_utc_at_local_minute(
    CivilDate date, unsigned minute, std::optional<int> offset_minutes) {
    @autoreleasepool {
        if (!valid_date(date) || minute > 1440) return std::nullopt;
        NSCalendar *calendar = kyiv_calendar();
        if (!calendar) return std::nullopt;
        using namespace std::chrono;
        const year_month_day ymd{year{date.year}, month{date.month}, day{date.day}};
        const sys_seconds wall = sys_seconds{sys_days{ymd}} + seconds{static_cast<std::int64_t>(minute) * 60};
        const year_month_day normalized{floor<days>(wall)};
        const CivilDate normalized_date{int(normalized.year()), unsigned(normalized.month()), unsigned(normalized.day())};
        if (!valid_date(normalized_date)) return std::nullopt;
        const auto minute_in_day = duration_cast<minutes>(wall - floor<days>(wall)).count();
        NSDateComponents *requested = [[NSDateComponents alloc] init];
        requested.era = 1;
        requested.year = normalized_date.year;
        requested.month = normalized_date.month;
        requested.day = normalized_date.day;
        requested.hour = minute_in_day / 60;
        requested.minute = minute_in_day % 60;
        requested.second = 0;
        // Anchor before the requested Kyiv day. All matching fields are supplied;
        // a later day/year or a normalized DST gap is rejected by the round trip.
        NSDate *anchor = [NSDate dateWithTimeIntervalSince1970:static_cast<double>(wall.time_since_epoch().count()) - 86400];
        std::optional<UtcInstant> result;
        for (const NSCalendarOptions repeated : {NSCalendarMatchFirst, NSCalendarMatchLast}) {
            NSDate *point = [calendar nextDateAfterDate:anchor matchingComponents:requested
                                              options:NSCalendarMatchStrictly | repeated];
            if (!point) continue;
            const double raw = point.timeIntervalSince1970;
            if (!std::isfinite(raw) || raw < first_utc || raw > last_utc || std::trunc(raw) != raw) continue;
            const UtcInstant candidate{static_cast<std::int64_t>(raw)};
            // The shared projection contract represents exact UTC minutes. A
            // historical subminute zone offset cannot be rounded into that type.
            if (candidate.epoch_seconds % 60 != 0) continue;
            if (offset_minutes && [calendar.timeZone secondsFromGMTForDate:point] !=
                static_cast<std::int64_t>(*offset_minutes) * 60) continue;
            if (!same_minute(requested, [calendar components:components fromDate:point])) continue;
            if (result && *result != candidate) return std::nullopt;
            result = candidate;
        }
        return result;
    }
}

std::optional<LocalMinute> kyiv_local_minute_at(UtcInstant instant) {
    @autoreleasepool {
        if (!supported(instant) || instant.epoch_seconds % 60 != 0) return std::nullopt;
        NSCalendar *calendar = kyiv_calendar();
        if (!calendar) return std::nullopt;
        NSDate *point = [NSDate dateWithTimeIntervalSince1970:static_cast<double>(instant.epoch_seconds)];
        NSDateComponents *local = [calendar components:components fromDate:point];
        const auto date = civil_date(local);
        if (!date || local.second != 0 || local.hour < 0 || local.hour > 23 ||
            local.minute < 0 || local.minute > 59) return std::nullopt;
        const LocalMinute result{*date, static_cast<unsigned>(local.hour * 60 + local.minute)};
        const auto roundtrip = kyiv_utc_at_local_minute(result.date, result.minute);
        if (!roundtrip || *roundtrip != instant) return std::nullopt;
        return result;
    }
}
} // namespace schedule
