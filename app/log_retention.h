#pragma once

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

// Operates only on regular diagnostic-YYYY-MM-DD.log files in the supplied
// directory. Never follows symlinks or removes unrelated files.
namespace log_retention {
namespace fs = std::filesystem;

inline bool managed_name(const std::wstring& name) {
    if (name.size() != 25 || name.compare(0, 11, L"diagnostic-") != 0 ||
        name.compare(21, 4, L".log") != 0 || name[15] != L'-' || name[18] != L'-') return false;
    for (size_t i = 11; i < 21; ++i) {
        if (i == 15 || i == 18) continue;
        if (name[i] < L'0' || name[i] > L'9') return false;
    }
    return true;
}

struct Entry { fs::path path; fs::file_time_type modified; std::uintmax_t size; };

inline bool clean(const fs::path& directory, fs::file_time_type now,
                  std::chrono::hours max_age, std::uintmax_t max_bytes) {
    std::error_code ec;
    if (!fs::exists(directory, ec)) return !ec;
    if (!fs::is_directory(fs::symlink_status(directory, ec)) || ec) return false;
    std::vector<Entry> entries;
    fs::directory_iterator it(directory, ec), end;
    if (ec) return false;
    for (; it != end; it.increment(ec)) {
        if (ec) return false;
        const auto path = it->path();
        if (!managed_name(path.filename().wstring())) continue;
        const auto status = it->symlink_status(ec);
        if (ec) return false;
        if (!fs::is_regular_file(status)) continue;
        const auto modified = it->last_write_time(ec);
        if (ec) return false;
        const auto size = it->file_size(ec);
        if (ec) return false;
        entries.push_back({path, modified, size});
    }
    if (ec) return false;
    std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
        return a.modified == b.modified ? a.path.native() < b.path.native() : a.modified < b.modified;
    });
    std::uintmax_t total = 0;
    for (const auto& entry : entries) {
        if (entry.size > UINTMAX_MAX - total) return false;
        total += entry.size;
    }
    for (const auto& entry : entries) {
        if (entry.modified > now - max_age && total <= max_bytes) continue;
        // Recheck immediately before removal to avoid following a replaced symlink.
        const auto status = fs::symlink_status(entry.path, ec);
        if (ec || !fs::is_regular_file(status)) return false;
        if (!fs::remove(entry.path, ec) || ec) return false;
        total -= entry.size;
    }
    return true;
}
} // namespace log_retention
