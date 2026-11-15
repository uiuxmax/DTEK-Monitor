// Foundation-backed four-stage lookup. The caller serializes this worker; no IO is started here.
#include "foundation_yasno_lookup.h"
#include "foundation_address_search.h"
#include <algorithm>
#include <exception>
#include <utility>

namespace yasno::lookup {
namespace {
bool json_type(std::string_view value) {
    value = value.substr(0, value.find(';'));
    while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) value.remove_prefix(1);
    while (!value.empty() && (value.back() == ' ' || value.back() == '\t')) value.remove_suffix(1);
    std::string normalized{value};
    for (auto& ch : normalized) if (ch >= 'A' && ch <= 'Z') ch += 'a' - 'A';
    return normalized == "application/json";
}
} // namespace

LookupResult lookup_once(LookupRequest request, Get get, StopToken stop) {
    @autoreleasepool {
    LookupResult result;
    result.selection = request.selection;
    if (!request.selection || !get) { result.failure = LookupFailure::schema; return result; }
    if (stop.stop_requested()) { result.failure = LookupFailure::cancelled; return result; }
    const auto fetch = [&](https::Resource resource, AddressResolution resolution = {})
        -> std::optional<https::Completion> {
        if (stop.stop_requested()) { result.failure = LookupFailure::cancelled; return std::nullopt; }
        if (!https::resource_path(resource)) { result.failure = LookupFailure::schema; return std::nullopt; }
        https::Request expected{request.selection, std::move(resolution), {}, resource};
        https::Completion completion{expected};
        try { completion = get(expected, stop); }
        catch (const std::exception&) { result.failure = LookupFailure::transport; return std::nullopt; }
        result.stages.push_back({resource.kind, completion.error, completion.status,
            completion.content_type, completion.body.size(), completion.diagnostic});
        const auto& returned = completion.request;
        if (returned.token != request.selection || returned.resource.kind != resource.kind ||
            returned.resource.query_utf8 != resource.query_utf8 ||
            returned.resource.street_id != resource.street_id ||
            returned.resource.house_id != resource.house_id ||
            returned.resolution.parse_state != expected.resolution.parse_state ||
            returned.resolution.address != expected.resolution.address ||
            returned.limits.body_bytes != expected.limits.body_bytes || returned.limits.total_ms != expected.limits.total_ms) {
            result.failure = LookupFailure::address_mismatch; return std::nullopt;
        }
        if (stop.stop_requested() || completion.error == https::Error::cancelled) {
            result.failure = LookupFailure::cancelled; return std::nullopt;
        }
        if (completion.status == 403 || completion.status == 429) { result.failure = LookupFailure::forbidden; return std::nullopt; }
        if (completion.cleanup_failed || completion.error != https::Error::none || completion.status != 200) {
            result.failure = LookupFailure::transport; return std::nullopt;
        }
        if (completion.content_type.size() > 256 || !json_type(completion.content_type) || completion.body.empty() || completion.body.size() > 2'000'000 ||
            !completion.received_at) { result.failure = LookupFailure::schema; return std::nullopt; }
        return completion;
    };
    std::string query;
    try { query = mac_json::utf8(mac_json::text(mac_address_search::street(request.street).name)); }
    catch (const std::exception&) { result.failure = LookupFailure::schema; return result; }
    const auto streets = fetch({https::ResourceKind::streets, query});
    if (!streets) return result;
    std::optional<AddressChoice> street;
    try {
        if (request.suggest_streets) {
            result.suggestions = address_choices(streets->body);
            return result;
        }
        street = street_address_choice(streets->body, request.street);
    }
    catch (const std::exception&) { result.failure = LookupFailure::schema; return result; }
    if (!street) { result.failure = LookupFailure::address_mismatch; return result; }
    const auto houses = fetch({https::ResourceKind::houses, request.house, street->id});
    if (!houses) return result;
    std::optional<AddressChoice> house;
    try {
        if (request.suggest_houses) {
            result.suggestions = address_choices(houses->body);
            return result;
        }
        house = exact_address_choice(houses->body, request.house);
    }
    catch (const std::exception&) { result.failure = LookupFailure::schema; return result; }
    if (!house) { result.failure = LookupFailure::address_mismatch; return result; }
    const auto group = fetch({https::ResourceKind::group, {}, street->id, house->id});
    if (!group) return result;
    const AddressReply street_reply{streets->body, "25", "902", {}, {}};
    const AddressReply house_reply{houses->body, "25", "902", street->id, {}};
    const AddressReply group_reply{group->body, "25", "902", street->id, house->id};
    result.resolution = resolve_address(street->label, house->label, street_reply, house_reply, group_reply);
    if (result.resolution.parse_state != schedule::ParseState::valid) {
        result.failure = LookupFailure::schema; return result;
    }
    if (!result.resolution.address.exact_source_match || !result.resolution.address.selected_identity) {
        result.failure = LookupFailure::address_mismatch; return result;
    }
    result.schedule = fetch({https::ResourceKind::planned_outages}, result.resolution);
    return result;
    }
}
} // namespace yasno::lookup
