#pragma once
#include "yasno_schedule_adapter.h"
#include "schedule_cache.h"
#include "popup_schedule.h"
#include "../research/schedule-engine/windows_kyiv_timezone.h"
#include <limits>

// Offline owner of one address, newest request and the derived popup model.
namespace schedule_flow {
class Flow {
    const schedule::KyivTimeZone& zone_;
    schedule::FreshnessPolicy policy_;
    schedule_cache::Cache cache_;
    std::optional<yasno::AddressResolution> resolution_;
    popup_schedule::Window model_;
    std::uint64_t request_ = 0;
    bool projection_dirty_ = false;

    static schedule::UtcInstant expiry(schedule::UtcInstant stamp, std::int64_t age) {
        // Engine age limits are inclusive; Window expiry is exclusive.
        const auto highest = (std::numeric_limits<std::int64_t>::max)();
        if (stamp.epoch_seconds >= highest - age) return schedule::UtcInstant{highest};
        return schedule::UtcInstant{stamp.epoch_seconds + age + 1};
    }
    static std::optional<popup_schedule::Day> project(const schedule::DatedSchedule& source,
                                                      schedule::UtcInstant until) {
        using namespace schedule;
        popup_schedule::Day day{source.local_date, popup_schedule::State::unavailable, false, until, {}};
        if (source.applicability == Applicability::emergency) day.state = popup_schedule::State::emergency;
        else if (source.applicability == Applicability::no_outages_unverified) day.state = popup_schedule::State::inactive;
        else if (source.applicability == Applicability::explicitly_applicable && source.interval_semantics_verified) {
            day.state = popup_schedule::State::published;
            day.verified = true;
            for (const auto& interval : source.outages) {
                const auto start = kyiv_local_minute_at(interval.starts_at_utc);
                const auto end = kyiv_local_minute_at(interval.ends_at_utc);
                if (!start || !end || start->date != source.local_date) return std::nullopt;
                unsigned end_minute = end->minute;
                if (end->date != source.local_date) {
                    const auto next = popup_schedule::next_date(source.local_date);
                    if (!next || end->date != *next || end_minute != 0) return std::nullopt;
                    end_minute = 1440;
                }
                if (start->minute >= end_minute) return std::nullopt;
                day.outages.push_back({start->minute, end_minute});
            }
        } else return std::nullopt;
        return day;
    }
    void empty(schedule::UtcInstant now) {
        projection_dirty_ = false;
        model_.replace(std::nullopt, std::nullopt, zone_.local_date_at(now), now);
    }
    bool refresh(schedule::UtcInstant now) {
        const auto* snapshot = cache_.current(now, zone_, policy_);
        const auto date = zone_.local_date_at(now);
        if (!snapshot || !date) { empty(now); return false; }
        if (!projection_dirty_) {
            // Validate the cache on every read, but convert unchanged interval
            // boundaries only once. Window handles expiry and date promotion.
            model_.advance(date, now);
            return model_.today().has_value() || model_.has_tomorrow();
        }
        projection_dirty_ = false;
        const auto fetch_expiry = expiry(snapshot->fetched_at_utc, policy_.max_age_seconds);
        const auto source_expiry = expiry(*snapshot->source_updated_at_utc,
            policy_.max_source_age_seconds.value_or(policy_.max_age_seconds));
        const auto until = fetch_expiry < source_expiry ? fetch_expiry : source_expiry;
        std::optional<popup_schedule::Day> today, tomorrow;
        const auto next = popup_schedule::next_date(*date);
        for (const auto& source : snapshot->days) {
            const auto day = project(source, until);
            if (!day) { empty(now); return false; }
            if (day->date == *date) today = day;
            else if (next && day->date == *next) tomorrow = day;
        }
        const bool preserve_tomorrow = model_.date() == date && model_.viewing_tomorrow();
        model_.replace(std::move(today), std::move(tomorrow), date, now);
        model_.select_tomorrow(preserve_tomorrow);
        return model_.today().has_value() || model_.has_tomorrow();
    }
public:
    // Single-owner object: the supplied zone must outlive the flow. Call view
    // immediately before rendering; no I/O, timers or countdown are started here.
    Flow(const schedule::KyivTimeZone& zone, schedule::FreshnessPolicy policy) : zone_(zone), policy_(policy) {}
    std::uint64_t select(yasno::AddressResolution resolution, schedule::UtcInstant now) {
        resolution_ = std::move(resolution);
        request_ = cache_.select(resolution_->address);
        empty(now);
        return request_;
    }
    std::uint64_t begin_request() { request_ = cache_.begin_request(); return request_; }
    bool receive(std::uint64_t request, const yasno::Response& response,
                 schedule::UtcInstant received_at, schedule::UtcInstant now) {
        if (!resolution_ || request != request_) return false;
        auto snapshot = yasno::parse_response(response, *resolution_, received_at);
        const bool accepted = cache_.replace(request, std::move(snapshot), now, zone_, policy_);
        projection_dirty_ = accepted;
        const bool visible = refresh(now);
        return accepted && visible;
    }
    const popup_schedule::Window& view(schedule::UtcInstant now) { refresh(now); return model_; }
    schedule::Outcome outcome(schedule::UtcInstant now) {
        refresh(now);
        const auto* snapshot = cache_.current(now, zone_, policy_);
        return snapshot ? schedule::evaluate(*snapshot, now, zone_, policy_) :
            schedule::Outcome{schedule::OutcomeKind::schedule_unavailable, std::nullopt};
    }
    void select_tomorrow(bool select) { model_.select_tomorrow(select); }
    void clear(schedule::UtcInstant now) {
        cache_.clear(); resolution_.reset(); request_ = 0; empty(now);
    }
};
} // namespace schedule_flow
