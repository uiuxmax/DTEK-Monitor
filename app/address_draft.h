#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace address_draft {

// Local user input only; this carries no provider identity or verification.
struct Draft {
    std::wstring street;
    std::wstring house;
    bool operator==(const Draft&) const = default;
};

std::optional<Draft> normalize(std::wstring_view street, std::wstring_view house);
Draft read(std::string_view settings_json);
std::optional<std::string> json_fields(const Draft& draft);

} // namespace address_draft
