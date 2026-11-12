#include "../../address_draft.h"
#include "foundation_json.h"

namespace address_draft {
namespace {
bool space(wchar_t ch) {
    return ch == L' ' || ch == 0x00a0 || ch == 0x1680 || (ch >= 0x2000 && ch <= 0x200a) ||
        ch == 0x2028 || ch == 0x2029 || ch == 0x202f || ch == 0x205f || ch == 0x3000;
}
std::wstring_view trim(std::wstring_view value) {
    while (!value.empty() && space(value.front())) value.remove_prefix(1);
    while (!value.empty() && space(value.back())) value.remove_suffix(1);
    return value;
}
bool valid(std::wstring_view value) {
    for (wchar_t ch : value) {
        const auto scalar = static_cast<std::uint32_t>(ch);
        if (scalar < 0x20 || (scalar >= 0x7f && scalar <= 0x9f) || scalar > 0x10ffff ||
            (scalar >= 0xd800 && scalar <= 0xdfff)) return false;
    }
    return true;
}
std::size_t utf16_size(std::wstring_view value) {
    std::size_t result = 0;
    for (wchar_t ch : value) result += static_cast<std::uint32_t>(ch) > 0xffff ? 2 : 1;
    return result;
}
} // namespace
std::optional<Draft> normalize(std::wstring_view street, std::wstring_view house) {
    if (!valid(street) || !valid(house)) return std::nullopt;
    street = trim(street); house = trim(house);
    if (street.empty() || house.empty() || utf16_size(street) > 120 || utf16_size(house) > 24) return std::nullopt;
    return Draft{std::wstring{street}, std::wstring{house}};
}
Draft read(std::string_view bytes) {
    @autoreleasepool {
        try {
            NSDictionary *root = mac_json::object(mac_json::parse(bytes));
            if (!root[@"draftStreet"] || !root[@"draftHouse"]) return {};
            const auto street = mac_json::wide(mac_json::string(root[@"draftStreet"]));
            const auto house = mac_json::wide(mac_json::string(root[@"draftHouse"]));
            if (street.empty() && house.empty()) return {};
            return normalize(street, house).value_or(Draft{});
        } catch (...) { return {}; }
    }
}
std::optional<std::string> json_fields(const Draft& draft) {
    @autoreleasepool {
        try {
            const bool empty = draft.street.empty() && draft.house.empty();
            const auto normalized = normalize(draft.street, draft.house);
            if (!empty && !normalized) return std::nullopt;
            const auto value = empty ? Draft{} : *normalized;
            const auto street = mac_json::encode(@[mac_json::text(value.street)]);
            const auto house = mac_json::encode(@[mac_json::text(value.house)]);
            return ",\n  \"draftStreet\": " + street.substr(1, street.size() - 2) +
                ",\n  \"draftHouse\": " + house.substr(1, house.size() - 2);
        } catch (...) { return std::nullopt; }
    }
}
} // namespace address_draft
