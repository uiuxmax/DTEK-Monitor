#pragma once
#include "../research/schedule-engine/schedule_engine.h"
#include <chrono>
#include <utility>
#include <algorithm>

// Display data only: callers must verify publication, identity and semantics
// before setting verified. No provider requests, storage or countdowns here.
namespace popup_schedule {
enum class State { unavailable, emergency, inactive, published };
struct Interval { unsigned start_minute; unsigned end_minute; };
struct Day {
    schedule::CivilDate date;
    State state = State::unavailable;
    bool verified = false;
    schedule::UtcInstant expires_at;
    std::vector<Interval> outages;
};

inline std::wstring clock_text(unsigned minute) {
    const auto hours = minute / 60, minutes = minute % 60;
    return std::wstring(hours < 10 ? L"0" : L"") + std::to_wstring(hours) + L":" +
        (minutes < 10 ? L"0" : L"") + std::to_wstring(minutes);
}

inline std::wstring range_text(const Interval& interval) {
    return clock_text(interval.start_minute) + L"–" + clock_text(interval.end_minute);
}

inline std::wstring duration_text(unsigned minutes) {
    const auto hours = minutes / 60, remainder = minutes % 60;
    if (!hours) return std::to_wstring(remainder) + L" хв";
    std::wstring value = std::to_wstring(hours) + L" год";
    if (remainder) value += L" " + std::to_wstring(remainder) + L" хв";
    return value;
}

inline unsigned total_outage_minutes(const Day* day) {
    if (!day || day->state != State::published) return 0;
    unsigned total = 0;
    for (const auto& interval : day->outages) total += interval.end_minute - interval.start_minute;
    return total;
}

inline std::wstring interval_text(const Day* day) {
    if (!day || day->state != State::published) return {};
    std::wstring rows;
    for (const auto& interval : day->outages) {
        if (!rows.empty()) rows += L"\r\n";
        rows += range_text(interval);
    }
    return rows;
}

struct LabelPosition { float left; unsigned row; };
inline constexpr float label_width = 84;
inline std::vector<LabelPosition> label_positions(const std::vector<Interval>& intervals,
                                                 float width) {
    constexpr float labelWidth = label_width, gap = 4;
    std::vector<LabelPosition> result;
    std::vector<float> ends;
    for (const auto& interval : intervals) {
        const float center = width * (interval.start_minute + interval.end_minute) / 2880.0f;
        const float left = std::clamp(center - labelWidth / 2, 0.0f, std::max(0.0f, width - labelWidth));
        unsigned row = 0;
        while (row < ends.size() && left < ends[row] + gap) ++row;
        if (row == ends.size()) ends.push_back(left + labelWidth);
        else ends[row] = left + labelWidth;
        result.push_back({left, row});
    }
    return result;
}
inline unsigned label_rows(const std::vector<LabelPosition>& labels) {
    unsigned rows = 0;
    for (const auto& label : labels) rows = std::max(rows, label.row + 1);
    return rows;
}

inline bool valid_date(schedule::CivilDate date) {
    return date.year >= 1601 && date.year <= 9999 && date.month >= 1 && date.month <= 12 &&
        date.day >= 1 && date.day <= 31 &&
        std::chrono::year_month_day{std::chrono::year{date.year},
            std::chrono::month{date.month}, std::chrono::day{date.day}}.ok();
}
inline std::optional<schedule::CivilDate> next_date(schedule::CivilDate date) {
    if (!valid_date(date) || date == schedule::CivilDate{9999, 12, 31}) return std::nullopt;
    const auto next = std::chrono::year_month_day{std::chrono::sys_days{
        std::chrono::year{date.year}/date.month/date.day} + std::chrono::days{1}};
    return schedule::CivilDate{int(next.year()), unsigned(next.month()), unsigned(next.day())};
}
inline bool usable(const Day& day, schedule::UtcInstant now) {
    if (!valid_date(day.date) || now >= day.expires_at) return false;
    if (day.state != State::published) return true;
    if (!day.verified) return false;
    unsigned end = 0;
    for (const auto& interval : day.outages) {
        if (interval.start_minute < end || interval.start_minute >= interval.end_minute ||
            interval.end_minute > 1440) return false;
        end = interval.end_minute;
    }
    return true;
}

class Window {
    std::optional<Day> today_, tomorrow_;
    std::optional<schedule::CivilDate> date_;
    bool tomorrow_selected_ = false;
public:
    void replace(std::optional<Day> today, std::optional<Day> tomorrow,
                 std::optional<schedule::CivilDate> date, schedule::UtcInstant now) {
        today_ = std::move(today);
        tomorrow_ = std::move(tomorrow);
        tomorrow_selected_ = false;
        advance(date, now);
    }
    void advance(std::optional<schedule::CivilDate> date, schedule::UtcInstant now) {
        if (!date || !valid_date(*date)) {
            today_.reset(); tomorrow_.reset(); date_.reset();
            tomorrow_selected_ = false;
            return;
        }
        if (date_ != date) tomorrow_selected_ = false;
        date_ = date;
        // Move rather than copy: yesterday is released, with no archive retained.
        if (tomorrow_ && tomorrow_->date == *date) today_ = std::move(tomorrow_);
        if (today_ && (today_->date != *date || !usable(*today_, now))) today_.reset();
        const auto next = next_date(*date);
        if (tomorrow_ && (!next || tomorrow_->date != *next ||
            tomorrow_->state != State::published || !usable(*tomorrow_, now))) tomorrow_.reset();
        if (!tomorrow_) tomorrow_selected_ = false;
    }
    void select_tomorrow(bool select) { tomorrow_selected_ = select && has_tomorrow(); }
    bool viewing_tomorrow() const { return tomorrow_selected_; }
    bool has_tomorrow() const { return tomorrow_.has_value(); }
    const std::optional<Day>& today() const { return today_; }
    const std::optional<Day>& tomorrow() const { return tomorrow_; }
    const std::optional<schedule::CivilDate>& date() const { return date_; }
    const Day* selected() const {
        const auto& selected = tomorrow_selected_ ? tomorrow_ : today_;
        return selected ? &*selected : nullptr;
    }
};
} // namespace popup_schedule
