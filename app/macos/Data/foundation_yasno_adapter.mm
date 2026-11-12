#include "../../yasno_schedule_adapter.h"
#include "../Time/foundation_kyiv_timezone.h"
#include "foundation_json.h"
#include "foundation_address_search.h"
#include <chrono>
#include <optional>
#include <set>
#include <stdexcept>

namespace yasno {
namespace {
using namespace schedule;
constexpr char source_url[] = "https://app.yasno.ua/api/blackout-service/public/shutdowns/regions/25/dsos/902/planned-outages";
[[noreturn]] void invalid() { throw std::invalid_argument("Unsupported provider schema"); }
std::string text(id value) { return mac_json::utf8(mac_json::string(value)); }
std::string numeric_id(id value, bool zero = false) {
    return std::to_string(mac_json::integer(value, 9'007'199'254'740'991ULL, zero));
}
int digits(std::string_view value, std::size_t at, std::size_t count) {
    if (at > value.size() || value.size() - at < count) return -1;
    int result = 0;
    for (std::size_t n = 0; n < count; ++n) {
        const char ch = value[at + n];
        if (ch < '0' || ch > '9') return -1;
        result = result * 10 + ch - '0';
    }
    return result;
}
struct Timestamp { CivilDate date; unsigned minute; UtcInstant utc; };
std::optional<Timestamp> timestamp(std::string_view value, bool day_date = false) {
    if (value.size() != 25 || value[4] != '-' || value[7] != '-' || value[10] != 'T' ||
        value[13] != ':' || value[16] != ':' || (value[19] != '+' && value[19] != '-') || value[22] != ':')
        return std::nullopt;
    const int y = digits(value, 0, 4), m = digits(value, 5, 2), d = digits(value, 8, 2);
    const int h = digits(value, 11, 2), minute = digits(value, 14, 2), second = digits(value, 17, 2);
    const int oh = digits(value, 20, 2), om = digits(value, 23, 2);
    if (y < 1601 || m < 1 || m > 12 || d < 1 || d > 31 || h < 0 || h > 23 ||
        minute < 0 || minute > 59 || second < 0 || second > 59 || oh < 0 || oh > 14 ||
        om < 0 || om > 59 || (oh == 14 && om != 0)) return std::nullopt;
    using namespace std::chrono;
    const year_month_day day{year{y}, month{static_cast<unsigned>(m)}, std::chrono::day{static_cast<unsigned>(d)}};
    if (!day.ok()) return std::nullopt;
    const int offset = (oh * 60 + om) * (value[19] == '+' ? 1 : -1);
    const sys_seconds wall = sys_seconds{sys_days{day}} + hours{h} + minutes{minute} + seconds{second};
    const UtcInstant utc{(wall - minutes{offset}).time_since_epoch().count()};
    if (day_date) {
        const auto verified = kyiv_utc_at_local_minute({y, static_cast<unsigned>(m), static_cast<unsigned>(d)},
            static_cast<unsigned>(h * 60 + minute), offset);
        if (second != 0 || !verified || *verified != utc) return std::nullopt;
    }
    return Timestamp{{y, static_cast<unsigned>(m), static_cast<unsigned>(d)}, static_cast<unsigned>(h * 60 + minute), utc};
}
DatedSchedule parse_day(NSDictionary *group, NSString *key, const ScheduleIdentity& identity) {
    NSDictionary *day = mac_json::object(group[key]);
    const auto stamp = timestamp(text(day[@"date"]), true);
    if (!stamp || stamp->minute != 0) invalid();
    DatedSchedule result;
    result.local_date = stamp->date; result.timezone = TimeZoneId::europe_kyiv; result.identity = identity;
    const auto status = text(day[@"status"]);
    if (status == "ScheduleApplies") result.applicability = Applicability::explicitly_applicable;
    else if (status == "EmergencyShutdowns") result.applicability = Applicability::emergency;
    else if (status == "NoOutages") result.applicability = Applicability::no_outages_unverified;
    else if (status == "WaitingForSchedule") result.applicability = Applicability::unknown;
    else invalid();
    NSArray *slots = mac_json::array(day[@"slots"]);
    unsigned previous = 0;
    bool uncertain = false;
    for (id value in slots) {
        NSDictionary *slot = mac_json::object(value);
        const auto start = static_cast<unsigned>(mac_json::integer(slot[@"start"], 1440, true));
        const auto end = static_cast<unsigned>(mac_json::integer(slot[@"end"], 1440, true));
        if (start != previous || end <= start) invalid();
        previous = end;
        const auto type = text(slot[@"type"]);
        if (type == "Possible") uncertain = true;
        else if (type != "Definite" && type != "NotPlanned") invalid();
        if (result.applicability != Applicability::explicitly_applicable || type != "Definite") continue;
        const auto from = kyiv_utc_at_local_minute(result.local_date, start);
        const auto until = kyiv_utc_at_local_minute(result.local_date, end);
        if (!from || !until || *from >= *until) invalid();
        result.outages.push_back({*from, *until});
    }
    if (slots.count == 0 || previous != 1440) {
        if (result.applicability == Applicability::explicitly_applicable || slots.count != 0) invalid();
    }
    result.interval_semantics_verified = !uncertain && result.applicability == Applicability::explicitly_applicable;
    return result;
}
std::optional<AddressChoice> exact_choice(std::string_view bytes, std::string_view label) {
    NSArray *values = mac_json::array(mac_json::parse(bytes));
    std::set<std::string> seen;
    std::optional<AddressChoice> selected;
    unsigned matches = 0;
    for (id value in values) {
        NSDictionary *choice = mac_json::object(value);
        const auto identifier = numeric_id(choice[@"id"]), name = text(choice[@"value"]);
        if (name.empty() || !seen.insert(identifier).second) invalid();
        // Raw UTF-8 equality, without Swift's canonical-equivalence comparison.
        if (name == label) { selected = {identifier, name}; ++matches; }
    }
    return matches == 1 ? selected : std::nullopt;
}
bool kyiv_scope(const AddressReply& value) { return value.region_id == "25" && value.dso_id == "902"; }
} // namespace

std::vector<AddressChoice> address_choices(std::string_view bytes) {
    @autoreleasepool {
        NSArray *values = mac_json::array(mac_json::parse(bytes));
        if (values.count > 1000) invalid();
        std::vector<AddressChoice> result;
        std::set<std::string> seen;
        for (id value in values) {
            NSDictionary *item = mac_json::object(value);
            const auto identifier = numeric_id(item[@"id"]);
            NSString *name = mac_json::string(item[@"value"]);
            if (name.length == 0 || name.length > 120 || !seen.insert(identifier).second) invalid();
            result.push_back({identifier, mac_json::utf8(name)});
        }
        return result;
    }
}
std::optional<AddressChoice> street_address_choice(std::string_view bytes, std::string_view input) {
    const auto choices = address_choices(bytes);
    std::optional<AddressChoice> result;
    for (const auto& choice : choices) {
        if (!mac_address_search::same_street(input, choice.label)) continue;
        if (result) return std::nullopt;
        result = choice;
    }
    return result;
}
std::optional<AddressChoice> exact_address_choice(std::string_view bytes, std::string_view label) {
    @autoreleasepool { return exact_choice(bytes, label); }
}
AddressResolution resolve_address(std::string_view street, std::string_view house,
    const AddressReply& streets, const AddressReply& houses, const AddressReply& group) {
    @autoreleasepool {
        AddressResolution result;
        auto& address = result.address;
        address.requested_street = street; address.requested_house = house;
        if (street.empty() || house.empty() || !kyiv_scope(streets) || !kyiv_scope(houses) || !kyiv_scope(group) ||
            !streets.street_id.empty() || !streets.house_id.empty() || !houses.house_id.empty()) return result;
        try {
            const auto a = exact_choice(streets.json, street);
            if (!a || houses.street_id != a->id || group.street_id != a->id) return result;
            address.region_id = streets.region_id; address.street_id = a->id; address.displayed_street = a->label;
            const auto b = exact_choice(houses.json, house);
            if (!b || group.house_id != b->id) return result;
            address.house_id = b->id; address.displayed_house = b->label;
            NSDictionary *pair = mac_json::object(mac_json::parse(group.json));
            if (pair.count != 2 || !pair[@"group"] || !pair[@"subgroup"]) invalid();
            const auto g = numeric_id(pair[@"group"]), s = numeric_id(pair[@"subgroup"], true);
            const auto key = s == "0" ? g : g + "." + s;
            address.identities = {{"yasno", key}}; address.selected_identity = address.identities.front();
            address.exact_source_match = true;
        } catch (...) { result.parse_state = ParseState::unsupported_schema; }
        return result;
    }
}
Snapshot parse_planned_outages(std::string_view bytes, Address address, UtcInstant fetched) {
    @autoreleasepool {
        Snapshot result;
        result.source = {"yasno", source_url}; result.address = std::move(address); result.fetched_at_utc = fetched;
        if (result.address.region_id != "25") { result.address.exact_source_match = false; return result; }
        if (!result.address.selected_identity || result.address.selected_identity->provider != "yasno" ||
            result.address.selected_identity->source_key.empty()) return result;
        try {
            NSDictionary *root = mac_json::object(mac_json::parse(bytes));
            NSDictionary *group = mac_json::object(root[mac_json::text(result.address.selected_identity->source_key)]);
            const auto updated = timestamp(text(group[@"updatedOn"]));
            if (!updated) invalid();
            result.source_updated_at_utc = updated->utc;
            result.days.push_back(parse_day(group, @"today", *result.address.selected_identity));
            result.days.push_back(parse_day(group, @"tomorrow", *result.address.selected_identity));
            using namespace std::chrono;
            const auto a = result.days[0].local_date, b = result.days[1].local_date;
            if (sys_days{year{b.year}/b.month/b.day} != sys_days{year{a.year}/a.month/a.day} + days{1}) invalid();
        } catch (...) {
            result.parse_state = ParseState::unsupported_schema;
            result.source_updated_at_utc.reset(); result.days.clear();
        }
        return result;
    }
}
Snapshot parse_planned_outages(std::string_view bytes, AddressResolution resolution, UtcInstant fetched) {
    if (resolution.parse_state == ParseState::valid) return parse_planned_outages(bytes, std::move(resolution.address), fetched);
    Snapshot result;
    result.source = {"yasno", source_url}; result.address = std::move(resolution.address);
    result.fetched_at_utc = fetched; result.parse_state = resolution.parse_state;
    return result;
}
Snapshot parse_response(const Response& response, AddressResolution resolution, UtcInstant received) {
    @autoreleasepool {
        Snapshot result;
        result.source = {"yasno", source_url}; result.address = resolution.address;
        result.parse_state = resolution.parse_state; result.failure = response.failure;
        if (result.failure != Failure::none) return result;
        if (response.http_status != 200) {
            result.failure = response.http_status == 204 ? Failure::unexpected_body : Failure::http;
            return result;
        }
        auto mime = response.content_type.substr(0, response.content_type.find(';'));
        while (!mime.empty() && (mime.front() == ' ' || mime.front() == '\t')) mime.remove_prefix(1);
        while (!mime.empty() && (mime.back() == ' ' || mime.back() == '\t')) mime.remove_suffix(1);
        std::string type{mime};
        for (char& ch : type) if (ch >= 'A' && ch <= 'Z') ch += 'a' - 'A';
        try {
            if (type != "application/json") invalid();
            mac_json::parse(response.body);
        } catch (...) { result.failure = Failure::unexpected_body; return result; }
        result = parse_planned_outages(response.body, std::move(resolution), received);
        if (result.parse_state != ParseState::valid) result.fetched_at_utc = UtcInstant{};
        return result;
    }
}
} // namespace yasno
