#pragma once

#include "../research/schedule-engine/schedule_engine.h"

#include <string_view>
#include <optional>
#include <string>
#include <vector>

namespace yasno {
struct AddressChoice { std::string id, label; };
std::vector<AddressChoice> address_choices(std::string_view json);
std::optional<AddressChoice> street_address_choice(std::string_view json, std::string_view input);

// Invalid JSON/schema raises a parsing exception; no or ambiguous exact label
// returns no choice. The caller must initialize its WinRT apartment.
std::optional<AddressChoice> exact_address_choice(std::string_view json,
                                                   std::string_view canonical_label);

// Context must be copied from the request that produced this body, never from
// the current UI selection. Street results have no street/house ID; house results
// carry the street ID; the group reply carries both. Only Kyiv/DSO 902 is supported.
struct AddressReply {
    std::string_view json;
    std::string region_id;
    std::string dso_id;
    std::string street_id;
    std::string house_id;
};

struct AddressResolution {
    schedule::Address address;
    schedule::ParseState parse_state = schedule::ParseState::valid;
};

// Labels are the exact canonical options selected by the user, not search text.
// Accepts only the observed single group/subgroup contract. Multiple or unknown
// group shapes are rejected; one returned pair does not prove a house has one line.
// Like the schedule parser, this requires a WinRT apartment and performs no I/O.
AddressResolution resolve_address(std::string_view street, std::string_view house,
                                  const AddressReply& streets,
                                  const AddressReply& houses,
                                  const AddressReply& group);

// Offline conversion only. The caller supplies an independently verified exact
// address and selected YASNO group; this function never resolves an address or
// accesses the network. The calling thread must initialize a WinRT apartment.
// Unknown schema and unsafe slot semantics fail closed.
schedule::Snapshot parse_planned_outages(std::string_view json,
                                          schedule::Address address,
                                          schedule::UtcInstant fetched_at_utc);

// Preserve an address-schema failure through the parser-to-engine path.
schedule::Snapshot parse_planned_outages(std::string_view json,
                                          AddressResolution resolution,
                                          schedule::UtcInstant fetched_at_utc);

// Supplied response metadata only; this function performs no transport or caching.
struct Response {
    schedule::Failure failure = schedule::Failure::none;
    int http_status = 0;
    std::string_view content_type;
    std::string_view body;
};

// Requires a complete HTTP 200 application/json body. Transport/body/schema
// failures carry no successful fetch time. No cached fallback is accepted.
// Receipt never verifies an address; the request-bound resolution is preserved.
// The calling thread must initialize a WinRT apartment, as for the naked parser.
schedule::Snapshot parse_response(const Response& response, AddressResolution resolution,
                                  schedule::UtcInstant received_at_utc);

} // namespace yasno
