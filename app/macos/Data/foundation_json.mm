#include "foundation_json.h"
#include <cmath>
#include <stdexcept>
#include <vector>

namespace mac_json {
namespace {
[[noreturn]] void invalid() { throw std::invalid_argument("Invalid JSON or Unicode"); }
unsigned hex4(std::string_view bytes, std::size_t offset) {
    if (offset > bytes.size() || bytes.size() - offset < 4) invalid();
    unsigned result = 0;
    for (unsigned n = 0; n < 4; ++n) {
        const char ch = bytes[offset + n];
        const int digit = ch >= '0' && ch <= '9' ? ch - '0' :
            ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 : ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : -1;
        if (digit < 0) invalid();
        result = result * 16 + static_cast<unsigned>(digit);
    }
    return result;
}
void valid_escapes(std::string_view bytes) {
    bool quoted = false;
    for (std::size_t i = 0; i < bytes.size(); ++i) {
        if (bytes[i] == '"') { quoted = !quoted; continue; }
        if (!quoted || bytes[i] != '\\') continue;
        if (++i == bytes.size()) invalid();
        if (bytes[i] != 'u') continue;
        const unsigned first = hex4(bytes, i + 1);
        i += 4;
        if (first >= 0xdc00 && first <= 0xdfff) invalid();
        if (first < 0xd800 || first > 0xdbff) continue;
        if (bytes.size() - i < 7 || bytes[i + 1] != '\\' || bytes[i + 2] != 'u') invalid();
        const unsigned second = hex4(bytes, i + 3);
        if (second < 0xdc00 || second > 0xdfff) invalid();
        i += 6;
    }
}
} // namespace

NSString *text(std::string_view bytes) {
    NSString *value = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
    if (!value) invalid();
    return value;
}
std::wstring wide(NSString *value) {
    static_assert(sizeof(wchar_t) == 4, "Mac wide strings contain Unicode scalars, not UTF-16 units");
    if (!value) invalid();
    std::wstring result;
    for (NSUInteger i = 0; i < value.length; ++i) {
        unsigned scalar = [value characterAtIndex:i];
        if (scalar >= 0xdc00 && scalar <= 0xdfff) invalid();
        if (scalar >= 0xd800 && scalar <= 0xdbff) {
            if (++i == value.length) invalid();
            const unsigned low = [value characterAtIndex:i];
            if (low < 0xdc00 || low > 0xdfff) invalid();
            scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
        }
        result.push_back(static_cast<wchar_t>(scalar));
    }
    return result;
}
std::wstring wide(std::string_view bytes) { return wide(text(bytes)); }
NSString *text(std::wstring_view value) {
    if (value.empty()) return @"";
    std::vector<unichar> units;
    units.reserve(value.size());
    for (const wchar_t raw : value) {
        const auto scalar = static_cast<std::uint32_t>(raw);
        if (scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) invalid();
        if (scalar <= 0xffff) units.push_back(static_cast<unichar>(scalar));
        else {
            units.push_back(static_cast<unichar>(0xd800 + ((scalar - 0x10000) >> 10)));
            units.push_back(static_cast<unichar>(0xdc00 + ((scalar - 0x10000) & 0x3ff)));
        }
    }
    return [[NSString alloc] initWithCharacters:units.data() length:units.size()];
}
NSString *string(id value) {
    if (![value isKindOfClass:NSString.class]) invalid();
    wide((NSString *)value); // Do not let a lossy NSString -> Swift/UTF-8 bridge repair input.
    return (NSString *)value;
}
std::string utf8(NSString *value) {
    string(value);
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!data) invalid();
    if (!data.length) return {};
    return {static_cast<const char *>(data.bytes), data.length};
}
id parse(std::string_view bytes, std::size_t cap) {
    if (bytes.empty() || bytes.size() > cap) invalid();
    text(bytes); // NSJSONSerialization also accepts UTF-16; this boundary accepts UTF-8 only.
    valid_escapes(bytes);
    NSError *error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes.data() length:bytes.size()]
        options:NSJSONReadingFragmentsAllowed error:&error];
    if (!value || error) invalid();
    return value;
}
NSDictionary *object(id value) {
    if (![value isKindOfClass:NSDictionary.class]) invalid();
    return (NSDictionary *)value;
}
NSArray *array(id value) {
    if (![value isKindOfClass:NSArray.class]) invalid();
    return (NSArray *)value;
}
double number(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) invalid();
    const double result = [(NSNumber *)value doubleValue];
    if (!std::isfinite(result)) invalid();
    return result;
}
std::uint64_t integer(id value, std::uint64_t maximum, bool allow_zero) {
    if (maximum > 9'007'199'254'740'991ULL) invalid();
    const double result = number(value);
    if (result < (allow_zero ? 0.0 : 1.0) || result > static_cast<double>(maximum) || std::trunc(result) != result) invalid();
    return static_cast<std::uint64_t>(result);
}
std::string encode(id value) {
    if (![NSJSONSerialization isValidJSONObject:value]) invalid();
    NSError *error = nil;
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:&error];
    if (!bytes || error) invalid();
    return {static_cast<const char *>(bytes.bytes), bytes.length};
}
} // namespace mac_json
