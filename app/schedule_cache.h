#pragma once
#include "../research/schedule-engine/schedule_engine.h"
#include <chrono>
#include <utility>

// One request-bound in-memory snapshot, never a schedule archive or disk store.
namespace schedule_cache {
class Cache {
    std::uint64_t generation_ = 0;
    std::optional<schedule::Address> address_;
    std::optional<schedule::Snapshot> value_;
    std::optional<schedule::UtcInstant> observed_at_;

    bool observe(schedule::UtcInstant now) {
        // Once invalidated, a clock rollback must not revive a previous view.
        if (observed_at_ && now < *observed_at_) {
            value_.reset();
            return false;
        }
        observed_at_ = now;
        return true;
    }
    static bool valid_date(schedule::CivilDate date) {
        return date.year >= 1601 && date.year <= 9999 && date.month >= 1 && date.month <= 12 &&
            date.day >= 1 && date.day <= 31 &&
            std::chrono::year_month_day{std::chrono::year{date.year}/date.month/date.day}.ok();
    }
    static std::optional<schedule::CivilDate> next_date(schedule::CivilDate date) {
        if (!valid_date(date) || date == schedule::CivilDate{9999, 12, 31}) return std::nullopt;
        const auto next = std::chrono::year_month_day{std::chrono::sys_days{
            std::chrono::year{date.year}/date.month/date.day} + std::chrono::days{1}};
        return schedule::CivilDate{int(next.year()), unsigned(next.month()), unsigned(next.day())};
    }
    bool retain(schedule::Snapshot& value, schedule::UtcInstant now,
                const schedule::KyivTimeZone& zone, schedule::FreshnessPolicy policy) const {
        using namespace schedule;
        if (!address_ || value.address != *address_ || !is_fresh(value, now, policy)) return false;
        const auto today = zone.local_date_at(now);
        if (!today || !valid_date(*today)) return false;
        const auto tomorrow = next_date(*today);
        std::vector<DatedSchedule> kept;
        bool seen_today = false, seen_tomorrow = false;
        for (auto& day : value.days) {
            const bool current = day.local_date == *today;
            if (!current && (!tomorrow || day.local_date != *tomorrow)) continue;
            bool& seen = current ? seen_today : seen_tomorrow;
            if (seen) return false;
            seen = true;
            if (day.timezone != TimeZoneId::europe_kyiv || !value.address.selected_identity ||
                day.identity != *value.address.selected_identity) return false;
            if (day.applicability == Applicability::unknown) continue;
            if (day.applicability == Applicability::explicitly_applicable) {
                if (!day.interval_semantics_verified) continue;
                std::optional<UtcInstant> previous_end;
                for (const auto& interval : day.outages) {
                    if (interval.starts_at_utc >= interval.ends_at_utc ||
                        (previous_end && interval.starts_at_utc < *previous_end) ||
                        zone.local_date_at(interval.starts_at_utc) != day.local_date ||
                        zone.local_date_at(interval.ends_at_utc - 1) != day.local_date) return false;
                    previous_end = interval.ends_at_utc;
                }
            } else {
                // Emergency/inactive explanations belong only to today. They
                // cannot publish tomorrow or carry outage intervals/countdowns.
                if (!current) continue;
                day.outages.clear();
                day.interval_semantics_verified = false;
            }
            kept.push_back(std::move(day));
        }
        if (kept.empty()) return false;
        if (kept.size() == 2 && kept.front().local_date != *today) std::swap(kept[0], kept[1]);
        value.days = std::move(kept);
        const auto outcome = evaluate(value, now, zone, policy).kind;
        return outcome == OutcomeKind::ready || outcome == OutcomeKind::emergency ||
            outcome == OutcomeKind::schedule_unavailable;
    }
public:
    // New selections (including A -> B -> A) invalidate every outstanding reply.
    std::uint64_t select(const schedule::Address& address) {
        clear();
        address_ = address;
        return generation_;
    }
    // A refresh does not discard an unexpired view while waiting. Only this
    // newest request may replace it; its failure clears it rather than falling back.
    std::uint64_t begin_request() { return ++generation_; }
    void clear() {
        ++generation_;
        address_.reset(); value_.reset(); observed_at_.reset();
    }
    bool replace(std::uint64_t request, schedule::Snapshot value, schedule::UtcInstant now,
                 const schedule::KyivTimeZone& zone, schedule::FreshnessPolicy policy) {
        if (request != generation_) return false;
        value_.reset();
        if (!observe(now) || !retain(value, now, zone, policy)) return false;
        value_ = std::move(value);
        return true;
    }
    // Read immediately before use. The pointer expires at the next cache mutation.
    const schedule::Snapshot* current(schedule::UtcInstant now, const schedule::KyivTimeZone& zone,
                                       schedule::FreshnessPolicy policy) {
        if (!observe(now)) return nullptr;
        if (value_ && !retain(*value_, now, zone, policy)) value_.reset();
        return value_ ? &*value_ : nullptr;
    }
};
} // namespace schedule_cache
