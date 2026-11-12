#include "https_resource.h"
#include <cstdint>
#include <string_view>

namespace yasno::https {
namespace {
constexpr std::wstring_view address_base = L"/api/blackout-service/public/shutdowns/addresses/v2/";
constexpr std::wstring_view planned_path = L"/api/blackout-service/public/shutdowns/regions/25/dsos/902/planned-outages";

bool valid_id(std::string_view value) {
    if (value.empty() || value.size() > 10 || value.front() == '0') return false;
    for (char ch : value) if (ch < '0' || ch > '9') return false;
    return true;
}

bool valid_utf8(std::string_view value) {
    if (value.empty() || value.size() > 256) return false;
    for (std::size_t i = 0; i < value.size();) {
        const auto first = static_cast<unsigned char>(value[i]);
        std::uint32_t codepoint = 0;
        std::size_t following = 0;
        if (first <= 0x7f) codepoint = first;
        else if (first >= 0xc2 && first <= 0xdf) { codepoint = first & 0x1f; following = 1; }
        else if (first >= 0xe0 && first <= 0xef) { codepoint = first & 0x0f; following = 2; }
        else if (first >= 0xf0 && first <= 0xf4) { codepoint = first & 0x07; following = 3; }
        else return false;
        if (following >= value.size() - i) return false;
        for (std::size_t j = 1; j <= following; ++j) {
            const auto next = static_cast<unsigned char>(value[i + j]);
            if ((next & 0xc0) != 0x80) return false;
            codepoint = (codepoint << 6) | (next & 0x3f);
        }
        if ((following == 2 && codepoint < 0x800) || (following == 3 && codepoint < 0x10000) ||
            (codepoint >= 0xd800 && codepoint <= 0xdfff) || codepoint > 0x10ffff ||
            codepoint <= 0x1f || (codepoint >= 0x7f && codepoint <= 0x9f)) return false;
        i += following + 1;
    }
    return true;
}

std::wstring encode(std::string_view value) {
    constexpr wchar_t hex[] = L"0123456789ABCDEF";
    std::wstring result;
    result.reserve(value.size() * 3);
    for (unsigned char byte : value) {
        if ((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
            (byte >= '0' && byte <= '9') || byte == '-' || byte == '.' || byte == '_' || byte == '~') {
            result.push_back(static_cast<wchar_t>(byte));
        } else {
            result.push_back(L'%');
            result.push_back(hex[byte >> 4]);
            result.push_back(hex[byte & 0x0f]);
        }
    }
    return result;
}

std::wstring widen_id(std::string_view value) {
    return std::wstring(value.begin(), value.end());
}
} // namespace

std::optional<std::wstring> resource_path(const Resource& resource) {
    switch (resource.kind) {
    case ResourceKind::planned_outages:
        if (!resource.query_utf8.empty() || !resource.street_id.empty() || !resource.house_id.empty()) return std::nullopt;
        return std::wstring{planned_path};
    case ResourceKind::streets:
        if (!valid_utf8(resource.query_utf8) || !resource.street_id.empty() || !resource.house_id.empty()) return std::nullopt;
        return std::wstring{address_base} + L"streets?regionId=25&query=" + encode(resource.query_utf8) + L"&dsoId=902";
    case ResourceKind::houses:
        if (!valid_utf8(resource.query_utf8) || !valid_id(resource.street_id) || !resource.house_id.empty()) return std::nullopt;
        return std::wstring{address_base} + L"houses?regionId=25&streetId=" + widen_id(resource.street_id) +
            L"&query=" + encode(resource.query_utf8) + L"&dsoId=902";
    case ResourceKind::group:
        if (!resource.query_utf8.empty() || !valid_id(resource.street_id) || !valid_id(resource.house_id)) return std::nullopt;
        return std::wstring{address_base} + L"group?regionId=25&streetId=" + widen_id(resource.street_id) +
            L"&houseId=" + widen_id(resource.house_id) + L"&dsoId=902";
    }
    return std::nullopt;
}
} // namespace yasno::https
