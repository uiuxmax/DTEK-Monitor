#pragma once

#include "kyiv_time_projection.h"

#include <memory>

namespace schedule {

// Returns no adapter when the named Kyiv zone is unavailable on this Windows host.
std::unique_ptr<KyivTimeZone> make_windows_kyiv_time_zone();

} // namespace schedule
