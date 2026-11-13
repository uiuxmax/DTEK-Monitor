#pragma once
#include "../../address_draft.h"
#include "../../schedule_flow.h"
#include <filesystem>
#include <cstddef>
#include <optional>
#include <string>

namespace mac_profile {
enum class ReadState { missing, loaded, unreadable, future_schema };
struct Settings {
    address_draft::Draft draft;
    std::string theme = "system";
    bool operator==(const Settings&) const = default;
};
struct SettingsRead { ReadState state; Settings value; };
// Faults are accepted only in a protected test build and never exposed in UI.
enum class WriteFault { none, partial_write, close_error, replace_error };
SettingsRead load_settings(const std::filesystem::path& profile);
bool save_settings(const std::filesystem::path& profile, const Settings& settings, WriteFault fault = WriteFault::none);

struct Receipt {
    address_draft::Draft draft;
    yasno::AddressResolution resolution;
    std::string body;
    schedule::UtcInstant received;
};
std::optional<Receipt> load_receipt(const std::filesystem::path& profile);
bool save_receipt(const std::filesystem::path& profile, const Receipt& receipt, WriteFault fault = WriteFault::none);
bool clean_logs(const std::filesystem::path& profile, std::filesystem::file_time_type now, std::size_t reserve_bytes = 0);
enum class DiagnosticEvent { startup, address_applied, lookup_ok, lookup_failed, source_stopped, wake, clock_changed, theme_changed, shutdown };
// Fixed event/status/reason only: no address, URL, body or arbitrary log text.
bool append_event(const std::filesystem::path& profile, DiagnosticEvent event, schedule::UtcInstant now,
                  int status = 0, int reason = 0);

// Revalidates original stamps on restore. Only the already validated receipt
// survives until its Kyiv midnight; no failed refresh can refresh its timestamps.
class DayReceipt {
    const schedule::KyivTimeZone& zone_;
    schedule::FreshnessPolicy incoming_;
    schedule_flow::Flow retained_;
    std::optional<Receipt> receipt_;
    std::optional<schedule::UtcInstant> observed_;
    void advance(schedule::UtcInstant now);
    bool install(Receipt value, const address_draft::Draft& selected, schedule::UtcInstant now, bool restoring);
public:
    explicit DayReceipt(const schedule::KyivTimeZone& zone,
        schedule::FreshnessPolicy policy = {3600, 300, 48 * 3600});
    bool accept(Receipt value, const address_draft::Draft& selected, schedule::UtcInstant now);
    bool restore(Receipt value, const address_draft::Draft& selected, schedule::UtcInstant now);
    void clear(schedule::UtcInstant now);
    const std::optional<Receipt>& saved(schedule::UtcInstant now);
    const popup_schedule::Window& view(schedule::UtcInstant now);
    schedule::Outcome outcome(schedule::UtcInstant now);
    std::optional<schedule::Countdown> estimate(schedule::UtcInstant now);
    void select_tomorrow(bool value);
};
} // namespace mac_profile
