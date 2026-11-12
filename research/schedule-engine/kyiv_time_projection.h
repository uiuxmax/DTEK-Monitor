#pragma once

#include "schedule_engine.h"

namespace schedule {

// Convert a minute boundary in a named Kyiv civil day to UTC. Minute 1440 is
// next midnight. Civil years must be 1601..9999 and the UTC result must also
// stay within 1601-01-01..9999-12-31 UTC. Missing or repeated times fail closed unless an
// explicit UTC offset disambiguates a repeated minute and matches Kyiv's zone.
std::optional<UtcInstant> kyiv_utc_at_local_minute(
    CivilDate date, unsigned minute, std::optional<int> utc_offset_minutes = std::nullopt);

struct LocalMinute {
    CivilDate date;
    unsigned minute;
};

// Project an exact UTC minute to a uniquely representable named Kyiv wall minute.
// Subminute, out-of-range and repeated local minutes fail closed. Midnight is
// minute zero of its own date, never minute 1440 of the previous date.
std::optional<LocalMinute> kyiv_local_minute_at(UtcInstant instant);

} // namespace schedule
