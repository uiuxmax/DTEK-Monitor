#pragma once
#import <Foundation/Foundation.h>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace mac_json {
id parse(std::string_view bytes, std::size_t cap = 2'000'000);
NSDictionary *object(id value);
NSArray *array(id value);
NSString *string(id value);
double number(id value);
std::uint64_t integer(id value, std::uint64_t maximum, bool allow_zero = false);
std::string utf8(NSString *value);
NSString *text(std::string_view utf8);
std::wstring wide(NSString *value);
std::wstring wide(std::string_view utf8);
NSString *text(std::wstring_view value);
std::string encode(id value);
} // namespace mac_json
