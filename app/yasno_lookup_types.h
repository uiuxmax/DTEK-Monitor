#pragma once
#include "https_contract.h"
#include <vector>

namespace yasno::lookup {
struct LookupRequest {
    std::uint64_t selection = 0;
    std::string street;
    std::string house;
    bool suggest_streets = false;
};
struct StageReceipt {
    https::ResourceKind resource;
    https::Error error;
    int status;
    std::string content_type;
    std::size_t body_bytes;
    std::string diagnostic;
};
enum class LookupFailure { none, transport, address_mismatch, schema, cancelled, forbidden };
struct LookupResult {
    std::uint64_t selection = 0;
    AddressResolution resolution;
    std::optional<https::Completion> schedule;
    std::vector<StageReceipt> stages;
    LookupFailure failure = LookupFailure::none;
    std::vector<AddressChoice> suggestions;
};
} // namespace yasno::lookup
