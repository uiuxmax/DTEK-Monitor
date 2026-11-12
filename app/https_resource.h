#pragma once

#include <optional>
#include <string>

namespace yasno::https {
enum class ResourceKind { planned_outages, streets, houses, group };

struct Resource {
    ResourceKind kind = ResourceKind::planned_outages;
    std::string query_utf8;
    std::string street_id;
    std::string house_id;
};

// Returns only the four supported YASNO paths. User text is validated as
// UTF-8 and encoded as data; parsed IDs cannot change the path structure.
std::optional<std::wstring> resource_path(const Resource& resource);
} // namespace yasno::https
