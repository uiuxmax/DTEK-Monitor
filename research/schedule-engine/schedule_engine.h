#pragma once

#include <cstdint>
#include <compare>
#include <optional>
#include <string>
#include <vector>

namespace schedule {

struct UtcInstant {
    std::int64_t epoch_seconds = 0;
    constexpr UtcInstant() = default;
    constexpr explicit UtcInstant(std::int64_t seconds) : epoch_seconds(seconds) {}
    auto operator<=>(const UtcInstant&) const = default;
};
constexpr UtcInstant operator+(UtcInstant value, std::int64_t seconds) {
    return UtcInstant{value.epoch_seconds + seconds};
}
constexpr UtcInstant operator-(UtcInstant value, std::int64_t seconds) {
    return UtcInstant{value.epoch_seconds - seconds};
}
constexpr std::int64_t operator-(UtcInstant a, UtcInstant b) {
    return a.epoch_seconds - b.epoch_seconds;
}

struct FreshnessPolicy {
    // Maximum age of the last successful complete fetch.
    std::int64_t max_age_seconds;
    std::int64_t allowed_clock_skew_seconds = 300;
    // Omission preserves the original shared fetch/source age limit.
    std::optional<std::int64_t> max_source_age_seconds = std::nullopt;
};

enum class TimeZoneId { europe_kyiv, unsupported };

struct CivilDate {
    int year;
    unsigned month;
    unsigned day;
    friend bool operator==(const CivilDate&, const CivilDate&) = default;
};

struct Source {
    std::string provider;
    std::string url;
};

struct ScheduleIdentity {
    std::string provider;
    std::string source_key;
    friend bool operator==(const ScheduleIdentity&, const ScheduleIdentity&) = default;
};

struct Address {
    std::string region_id;
    std::string street_id;
    std::string house_id;
    std::string requested_street;
    std::string requested_house;
    std::string displayed_street;
    std::string displayed_house;
    bool exact_source_match = false;
    std::vector<ScheduleIdentity> identities;
    std::optional<ScheduleIdentity> selected_identity;
    bool line_explicitly_resolved = false;
    friend bool operator==(const Address&, const Address&) = default;
};

enum class Failure { none, dns, tls, http, timeout, unexpected_body };
enum class ParseState { valid, unsupported_schema };
enum class Applicability { explicitly_applicable, emergency, no_outages_unverified, unknown };
enum class OutcomeKind {
    ready, address_unverified, ambiguous_line, emergency,
    schedule_unavailable, stale, unsupported_schema, source_unavailable
};
enum class EventKind { outage_starts, power_restored };

// UTC instants. The provider adapter must establish that these really describe
// outages before constructing this type. No raw provider slot is interpreted here.
struct OutageInterval {
    UtcInstant starts_at_utc;
    UtcInstant ends_at_utc; // Exclusive: [start, end).
};

struct DatedSchedule {
    CivilDate local_date;
    TimeZoneId timezone = TimeZoneId::unsupported; // Europe/Kyiv only.
    ScheduleIdentity identity;
    Applicability applicability = Applicability::unknown;
    bool interval_semantics_verified = false;
    std::vector<OutageInterval> outages;
};

struct Snapshot {
    Source source;
    Address address;
    Failure failure = Failure::none;
    ParseState parse_state = ParseState::valid;
    UtcInstant fetched_at_utc;
    std::optional<UtcInstant> source_updated_at_utc;
    std::vector<DatedSchedule> days;
};

// The core never assumes a UTC offset or computes DST rules. Windows callers
// can use the named-zone adapter in windows_kyiv_timezone.h; synthetic tests
// also inject deterministic explicit offsets.
class KyivTimeZone {
public:
    virtual ~KyivTimeZone() = default;
    virtual std::optional<CivilDate> local_date_at(UtcInstant utc) const = 0;
};

struct Countdown {
    EventKind event;
    UtcInstant event_at_utc;
    std::int64_t remaining_seconds;
    std::string ukrainian_text;
};

struct Outcome {
    OutcomeKind kind;
    std::optional<Countdown> countdown;
};

// Positive durations >= 60 s are rounded UP to a whole minute. Durations
// 1..59 s display "менше 1 хв"; zero displays "зараз".
std::string format_ukrainian_countdown(EventKind event, std::int64_t remaining_seconds);
// Checks only timestamp consistency and policy; no address or schedule validity.
bool is_fresh(const Snapshot& snapshot, UtcInstant now_utc, FreshnessPolicy freshness);
Outcome evaluate(const Snapshot& snapshot, UtcInstant now_utc,
                 const KyivTimeZone& zone, FreshnessPolicy freshness);
const char* outcome_name(OutcomeKind kind);

} // namespace schedule
