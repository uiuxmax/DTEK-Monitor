#include "schedule_engine.h"

#include <algorithm>
#include <chrono>
#include <limits>
#include <sstream>

namespace schedule {
namespace {

std::optional<std::chrono::sys_days> as_days(CivilDate value) {
    using namespace std::chrono;
    // Validate the original integers before chrono's compact fields can narrow them.
    if (value.year < int(year::min()) || value.year > int(year::max()) ||
        value.month < 1 || value.month > 12 || value.day < 1 || value.day > 31)
        return std::nullopt;
    const year_month_day ymd{year{value.year}, month{value.month}, day{value.day}};
    if (!ymd.ok()) return std::nullopt;
    return sys_days{ymd};
}

bool same_source(const ScheduleIdentity& identity, const Source& source) {
    return !identity.source_key.empty() && identity.provider == source.provider;
}

bool covers(const DatedSchedule& day, const ScheduleIdentity& selected,
            CivilDate date) {
    return day.local_date == date && day.identity == selected;
}

Outcome denied(OutcomeKind kind) { return {kind, std::nullopt}; }

bool exceeds(UtcInstant later, UtcInstant earlier, std::int64_t limit) {
    if (later <= earlier) return false;
    // Unsigned subtraction gives the exact nonnegative distance, including
    // distances larger than INT64_MAX, without signed addition/subtraction.
    return static_cast<std::uint64_t>(later.epoch_seconds) -
        static_cast<std::uint64_t>(earlier.epoch_seconds) >
        static_cast<std::uint64_t>(limit);
}

OutcomeKind day_gate(const DatedSchedule& day) {
    if (day.applicability == Applicability::emergency) return OutcomeKind::emergency;
    if (day.applicability != Applicability::explicitly_applicable ||
        !day.interval_semantics_verified || day.outages.empty()) {
        return OutcomeKind::schedule_unavailable;
    }
    return OutcomeKind::ready;
}

std::string duration_text(std::int64_t seconds) {
    // The event selector only calls this with a nonnegative duration.
    if (seconds == 0) return "зараз";
    if (seconds < 60) return "менше 1 хв";
    const auto minutes = seconds / 60 + (seconds % 60 != 0 ? 1 : 0);
    const auto hours = minutes / 60;
    const auto remainder = minutes % 60;
    std::ostringstream out;
    if (hours != 0) out << hours << " г";
    if (remainder != 0 || hours == 0) {
        if (hours != 0) out << ' ';
        out << remainder << " хв";
    }
    return out.str();
}

} // namespace

std::string format_ukrainian_countdown(EventKind event, std::int64_t remaining_seconds) {
    if (remaining_seconds < 0) remaining_seconds = 0;
    const char* prefix = event == EventKind::outage_starts
        ? "Відключення через " : "Відновлення через ";
    if (remaining_seconds == 0) return event == EventKind::outage_starts
        ? "Відключення зараз" : "Відновлення зараз";
    return std::string(prefix) + duration_text(remaining_seconds);
}

bool is_fresh(const Snapshot& s, UtcInstant now, FreshnessPolicy freshness) {
    const auto source_max_age = freshness.max_source_age_seconds.value_or(
        freshness.max_age_seconds);
    if (freshness.max_age_seconds < 0 || freshness.allowed_clock_skew_seconds < 0 ||
        source_max_age < 0 || !s.source_updated_at_utc) return false;
    const auto source_updated = *s.source_updated_at_utc;
    return !exceeds(s.fetched_at_utc, now, freshness.allowed_clock_skew_seconds) &&
        !exceeds(source_updated, now, freshness.allowed_clock_skew_seconds) &&
        !exceeds(source_updated, s.fetched_at_utc, freshness.allowed_clock_skew_seconds) &&
        !exceeds(now, s.fetched_at_utc, freshness.max_age_seconds) &&
        !exceeds(now, source_updated, source_max_age);
}

Outcome evaluate(const Snapshot& s, UtcInstant now, const KyivTimeZone& zone,
                 FreshnessPolicy freshness) {
    if (s.failure != Failure::none) return denied(OutcomeKind::source_unavailable);
    if (s.parse_state != ParseState::valid || s.source.provider.empty() ||
        s.source.url.empty()) return denied(OutcomeKind::unsupported_schema);

    const auto& address = s.address;
    if (!address.exact_source_match || address.region_id.empty() ||
        address.street_id.empty() || address.house_id.empty() ||
        address.requested_street.empty() || address.requested_house.empty() ||
        address.requested_street != address.displayed_street ||
        address.requested_house != address.displayed_house ||
        address.identities.empty()) return denied(OutcomeKind::address_unverified);

    if (address.identities.size() > 1 && !address.line_explicitly_resolved)
        return denied(OutcomeKind::ambiguous_line);
    if (!address.selected_identity) return denied(OutcomeKind::address_unverified);
    const auto& selected = *address.selected_identity;
    if (!same_source(selected, s.source) ||
        std::find(address.identities.begin(), address.identities.end(), selected)
            == address.identities.end()) return denied(OutcomeKind::address_unverified);

    // A fresh download of old source data does not make the schedule fresh.
    if (!is_fresh(s, now, freshness)) return denied(OutcomeKind::stale);

    const auto local_today = zone.local_date_at(now);
    if (!local_today || !as_days(*local_today))
        return denied(OutcomeKind::unsupported_schema);

    std::vector<OutageInterval> intervals;
    for (const auto& day : s.days) {
        if (day.timezone != TimeZoneId::europe_kyiv || !as_days(day.local_date) ||
            !same_source(day.identity, s.source) || day.identity != selected) {
            return denied(OutcomeKind::unsupported_schema);
        }
        for (const auto& interval : day.outages) {
            if (interval.starts_at_utc >= interval.ends_at_utc ||
                zone.local_date_at(interval.starts_at_utc) != day.local_date ||
                !zone.local_date_at(interval.ends_at_utc - 1)) {
                return denied(OutcomeKind::unsupported_schema);
            }
            if (day.applicability == Applicability::explicitly_applicable &&
                day.interval_semantics_verified) intervals.push_back(interval);
        }
    }
    const DatedSchedule* today = nullptr;
    for (const auto& day : s.days) {
        if (covers(day, selected, *local_today)) {
            if (today) return denied(OutcomeKind::unsupported_schema);
            today = &day;
        }
    }
    if (!today) return denied(OutcomeKind::schedule_unavailable);
    const auto today_gate = day_gate(*today);
    if (today_gate != OutcomeKind::ready) return denied(today_gate);

    std::sort(intervals.begin(), intervals.end(), [](const auto& a, const auto& b) {
        return a.starts_at_utc < b.starts_at_utc;
    });
    std::vector<OutageInterval> merged;
    for (const auto& interval : intervals) {
        if (!merged.empty() && interval.starts_at_utc <= merged.back().ends_at_utc)
            merged.back().ends_at_utc = std::max(merged.back().ends_at_utc,
                                                  interval.ends_at_utc);
        else merged.push_back(interval);
    }

    std::optional<Countdown> countdown;
    for (const auto& interval : merged) {
        if (now < interval.starts_at_utc) {
            countdown = Countdown{EventKind::outage_starts, interval.starts_at_utc,
                                  interval.starts_at_utc - now, {}};
            break;
        }
        if (now < interval.ends_at_utc) {
            countdown = Countdown{EventKind::power_restored, interval.ends_at_utc,
                                  interval.ends_at_utc - now, {}};
            break;
        }
    }
    if (!countdown) return denied(OutcomeKind::schedule_unavailable);

    const auto event_date = zone.local_date_at(countdown->event_at_utc);
    if (!event_date || !as_days(*event_date))
        return denied(OutcomeKind::unsupported_schema);
    const auto from = *as_days(*local_today);
    const auto to = *as_days(*event_date);
    if (to < from || to - from > std::chrono::days{7})
        return denied(OutcomeKind::schedule_unavailable);
    for (auto date = from; date <= to; date += std::chrono::days{1}) {
        const std::chrono::year_month_day ymd{date};
        CivilDate expected{int(ymd.year()), unsigned(ymd.month()), unsigned(ymd.day())};
        const DatedSchedule* found = nullptr;
        for (const auto& day : s.days) {
            if (covers(day, selected, expected)) {
                if (found) return denied(OutcomeKind::unsupported_schema);
                found = &day;
            }
        }
        if (!found) return denied(OutcomeKind::schedule_unavailable);
        const auto gate = day_gate(*found);
        if (gate != OutcomeKind::ready) return denied(gate);
    }

    countdown->ukrainian_text = format_ukrainian_countdown(countdown->event,
                                                             countdown->remaining_seconds);
    return {OutcomeKind::ready, std::move(countdown)};
}

const char* outcome_name(OutcomeKind kind) {
    switch (kind) {
    case OutcomeKind::ready: return "ready";
    case OutcomeKind::address_unverified: return "address_unverified";
    case OutcomeKind::ambiguous_line: return "ambiguous_line";
    case OutcomeKind::emergency: return "emergency";
    case OutcomeKind::schedule_unavailable: return "schedule_unavailable";
    case OutcomeKind::stale: return "stale";
    case OutcomeKind::unsupported_schema: return "unsupported_schema";
    case OutcomeKind::source_unavailable: return "source_unavailable";
    }
    return "invalid";
}

} // namespace schedule
