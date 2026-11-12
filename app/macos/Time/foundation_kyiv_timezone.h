#pragma once

#include "kyiv_time_projection.h"
#include <memory>

namespace schedule {
// No fallback to the system zone or a fixed offset if Europe/Kyiv is absent.
std::unique_ptr<KyivTimeZone> make_foundation_kyiv_time_zone();
} // namespace schedule
