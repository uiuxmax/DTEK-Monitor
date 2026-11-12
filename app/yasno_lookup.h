#pragma once

#include "yasno_lookup_types.h"
#include <functional>
#include <stop_token>
#include <vector>

namespace yasno::lookup {
using Get = std::function<https::Completion(https::Request, std::stop_token)>;

// One request-bound streets -> houses -> group -> schedule chain, at most four
// GETs. The caller initializes a WinRT apartment and owns cancellation.
LookupResult lookup_once(LookupRequest request, Get get, std::stop_token stop = {});
} // namespace yasno::lookup
