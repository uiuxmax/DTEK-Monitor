#include "foundation_profile.h"
#include "foundation_json.h"
#include "foundation_address_search.h"
#include "../../log_retention.h"
#include <cerrno>
#include <cstdlib>
#include <cstdio>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <array>
#include <chrono>
#include <charconv>
#include <limits>

namespace mac_profile {
namespace {
namespace fs = std::filesystem;
struct Descriptor {
    int value = -1;
    explicit Descriptor(int fd = -1) : value(fd) {}
    ~Descriptor() { if (value >= 0) ::close(value); }
    Descriptor(const Descriptor&) = delete;
    Descriptor& operator=(const Descriptor&) = delete;
};
bool owned_profile(const fs::path& profile) {
    std::error_code error;
    const auto canonical = fs::canonical(profile, error);
    if (error || canonical != profile.lexically_normal()) return false;
#if defined(DTEKMONITOR_MAC_TEST_BUILD)
    const char *base = std::getenv("DTEKMONITOR_TEST_PROFILE");
    const char *network = std::getenv("DTEKMONITOR_DISABLE_PROVIDER");
    const char *login = std::getenv("DTEKMONITOR_AUTOSTART_TEST_MODE");
    if (!base || !network || !login || std::string_view{network} != "1" || std::string_view{login} != "1") return false;
    const fs::path root = fs::canonical(base, error);
    if (error || root != fs::path{base}) return false;
    const auto relative = canonical.lexically_relative(root);
    if (relative.empty() || *relative.begin() == "..") return false;
#endif
    return true;
}
int open_profile(const fs::path& profile) {
    return owned_profile(profile) ? ::open(profile.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1;
}
struct Read { ReadState state; std::string bytes; };
Read read_file(int directory, const char *leaf, std::size_t cap) {
    if (directory < 0) return {ReadState::unreadable, {}};
    Descriptor file{::openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)};
    if (file.value < 0) return {errno == ENOENT ? ReadState::missing : ReadState::unreadable, {}};
    struct stat attributes{};
    if (::fstat(file.value, &attributes) != 0 || !S_ISREG(attributes.st_mode) || attributes.st_size < 0 ||
        static_cast<std::uintmax_t>(attributes.st_size) > cap) return {ReadState::unreadable, {}};
    std::string bytes;
    std::array<char, 4096> buffer{};
    while (true) {
        const auto count = ::read(file.value, buffer.data(), buffer.size());
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return {ReadState::unreadable, {}};
        if (!count) break;
        if (static_cast<std::size_t>(count) > cap - bytes.size()) return {ReadState::unreadable, {}};
        bytes.append(buffer.data(), static_cast<std::size_t>(count));
    }
    if (bytes.size() != static_cast<std::uintmax_t>(attributes.st_size)) return {ReadState::unreadable, {}};
    return {ReadState::loaded, std::move(bytes)};
}
bool replace_file(int directory, const char *leaf, std::string_view bytes, WriteFault fault) {
    if (directory < 0) return false;
#if !defined(DTEKMONITOR_MAC_TEST_BUILD)
    if (fault != WriteFault::none) return false;
#endif
    const std::string temporary = ".dtek-" + mac_json::utf8(NSUUID.UUID.UUIDString) + ".tmp";
    Descriptor file{::openat(directory, temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)};
    if (file.value < 0) return false;
    bool good = true;
    std::size_t position = 0;
    while (position < bytes.size()) {
        const std::size_t amount = fault == WriteFault::partial_write ? 1 : bytes.size() - position;
        const auto count = ::write(file.value, bytes.data() + position, amount);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { good = false; break; }
        position += static_cast<std::size_t>(count);
        if (fault == WriteFault::partial_write) { good = false; break; }
    }
    if (::fsync(file.value) != 0) good = false;
    if (::close(file.value) != 0) good = false;
    file.value = -1;
    if (fault == WriteFault::close_error || fault == WriteFault::replace_error) good = false;
    struct stat target{};
    if (::fstatat(directory, leaf, &target, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(target.st_mode)) good = false;
    } else if (errno != ENOENT) good = false;
    if (good && ::renameat(directory, temporary.c_str(), directory, leaf) == 0) {
        // Atomic replacement is established. Directory flush is best-effort;
        // this API does not claim power-loss durability of the hosting volume.
        ::fsync(directory);
        return true;
    }
    ::unlinkat(directory, temporary.c_str(), 0); // Only the O_EXCL file owned by this call.
    return false;
}
bool theme_valid(std::string_view value) { return value == "system" || value == "light" || value == "dark"; }
std::string text(id value) { return mac_json::utf8(mac_json::string(value)); }
ReadState format(NSDictionary *root, std::string_view expected) {
    if (text(root[@"format"]) != expected) return ReadState::unreadable;
    const auto version = mac_json::integer(root[@"version"], 9'007'199'254'740'991ULL);
    return version == 1 ? ReadState::loaded : ReadState::future_schema;
}
SettingsRead settings(const Read& file) {
    if (file.state != ReadState::loaded) return {file.state, {}};
    try {
        NSDictionary *root = mac_json::object(mac_json::parse(file.bytes, 64 * 1024));
        const auto state = format(root, "dtek-monitor-macos-settings");
        if (state != ReadState::loaded) return {state, {}};
        const auto street = mac_json::wide(mac_json::string(root[@"draftStreet"]));
        const auto house = mac_json::wide(mac_json::string(root[@"draftHouse"]));
        const auto draft = address_draft::normalize(street, house);
        if ((!street.empty() || !house.empty()) && !draft) return {ReadState::unreadable, {}};
        const auto theme = text(root[@"theme"]);
        if (!theme_valid(theme)) return {ReadState::unreadable, {}};
        return {ReadState::loaded, {draft.value_or(address_draft::Draft{}), theme}};
    } catch (...) { return {ReadState::unreadable, {}}; }
}
bool canonical_number(std::string_view bytes) {
    std::uint64_t value = 0;
    const auto result = std::from_chars(bytes.data(), bytes.data() + bytes.size(), value);
    return !bytes.empty() && bytes.front() != '0' && result.ec == std::errc{} && result.ptr == bytes.data() + bytes.size() &&
        value <= 9'007'199'254'740'991ULL;
}
bool canonical_group(std::string_view bytes) {
    const auto dot = bytes.find('.');
    return dot == std::string_view::npos ? canonical_number(bytes) :
        canonical_number(bytes.substr(0, dot)) && canonical_number(bytes.substr(dot + 1));
}
std::optional<Receipt> receipt(const Read& file) {
    if (file.state != ReadState::loaded) return std::nullopt;
    try {
        NSDictionary *root = mac_json::object(mac_json::parse(file.bytes, 2'010'000));
        if (format(root, "dtek-monitor-macos-receipt") != ReadState::loaded || text(root[@"provider"]) != "yasno" ||
            text(root[@"regionId"]) != "25" || text(root[@"dsoId"]) != "902") return std::nullopt;
        const auto draft = address_draft::normalize(mac_json::wide(mac_json::string(root[@"draftStreet"])),
            mac_json::wide(mac_json::string(root[@"draftHouse"])));
        if (!draft) return std::nullopt;
        schedule::Address address;
        address.region_id = "25";
        address.street_id = text(root[@"streetId"]); address.house_id = text(root[@"houseId"]);
        address.requested_street = address.displayed_street = text(root[@"street"]);
        address.requested_house = address.displayed_house = text(root[@"house"]);
        const auto group = text(root[@"group"]);
        if (!canonical_number(address.street_id) || !canonical_number(address.house_id) || !canonical_group(group) ||
            !address_draft::normalize(mac_json::wide(address.displayed_street), mac_json::wide(address.displayed_house))) return std::nullopt;
        address.exact_source_match = true;
        address.identities = {{"yasno", group}}; address.selected_identity = address.identities.front();
        address.line_explicitly_resolved = false;
        const auto received = mac_json::integer(root[@"receivedAt"], 253402300799ULL);
        auto body = mac_json::encode(mac_json::object(root[@"body"]));
        if (body.empty() || body.size() > 2'000'000) return std::nullopt;
        return Receipt{*draft, {std::move(address)}, std::move(body), schedule::UtcInstant{static_cast<std::int64_t>(received)}};
    } catch (...) { return std::nullopt; }
}
schedule::FreshnessPolicy retention(schedule::FreshnessPolicy policy) {
    const auto extend = [](std::int64_t age) {
        constexpr std::int64_t extra = 26 * 3600;
        return age > std::numeric_limits<std::int64_t>::max() - extra ? age : age + extra;
    };
    policy.max_source_age_seconds = extend(policy.max_source_age_seconds.value_or(policy.max_age_seconds));
    policy.max_age_seconds = extend(policy.max_age_seconds);
    return policy;
}
} // namespace

SettingsRead load_settings(const fs::path& profile) {
    @autoreleasepool { Descriptor directory{open_profile(profile)}; return settings(read_file(directory.value, "settings.json", 64 * 1024)); }
}
bool save_settings(const fs::path& profile, const Settings& value, WriteFault fault) {
    @autoreleasepool {
        try {
            const auto normalized = address_draft::normalize(value.draft.street, value.draft.house);
            if ((!value.draft.street.empty() || !value.draft.house.empty()) && !normalized) return false;
            if (!theme_valid(value.theme)) return false;
            Descriptor directory{open_profile(profile)};
            const auto current = settings(read_file(directory.value, "settings.json", 64 * 1024));
            if (current.state != ReadState::missing && current.state != ReadState::loaded) return false;
            const auto draft = normalized.value_or(address_draft::Draft{});
            const auto bytes = mac_json::encode(@{@"format": @"dtek-monitor-macos-settings", @"version": @1,
                @"draftStreet": mac_json::text(draft.street), @"draftHouse": mac_json::text(draft.house), @"theme": mac_json::text(value.theme)});
            return replace_file(directory.value, "settings.json", bytes, fault);
        } catch (...) { return false; }
    }
}
std::optional<Receipt> load_receipt(const fs::path& profile) {
    @autoreleasepool { Descriptor directory{open_profile(profile)}; return receipt(read_file(directory.value, "receipt.json", 2'010'000)); }
}
bool save_receipt(const fs::path& profile, const Receipt& value, WriteFault fault) {
    @autoreleasepool {
        try {
            const auto draft = address_draft::normalize(value.draft.street, value.draft.house);
            const auto& address = value.resolution.address;
            if (!draft || value.resolution.parse_state != schedule::ParseState::valid || !address.exact_source_match ||
                address.region_id != "25" || address.identities.size() != 1 || !address.selected_identity ||
                address.identities.front() != *address.selected_identity || address.selected_identity->provider != "yasno" ||
                !canonical_number(address.street_id) || !canonical_number(address.house_id) ||
                !canonical_group(address.selected_identity->source_key) || value.body.empty() || value.body.size() > 2'000'000 ||
                value.received.epoch_seconds <= 0 || value.received.epoch_seconds > 253402300799LL) return false;
            const auto bytes = mac_json::encode(@{@"format": @"dtek-monitor-macos-receipt", @"version": @1,
                @"provider": @"yasno", @"regionId": @"25", @"dsoId": @"902", @"draftStreet": mac_json::text(draft->street),
                @"draftHouse": mac_json::text(draft->house), @"streetId": mac_json::text(address.street_id),
                @"houseId": mac_json::text(address.house_id), @"street": mac_json::text(address.displayed_street),
                @"house": mac_json::text(address.displayed_house), @"group": mac_json::text(address.selected_identity->source_key),
                @"body": mac_json::object(mac_json::parse(value.body)), @"receivedAt": @(value.received.epoch_seconds)});
            if (bytes.size() > 2'010'000) return false;
            Descriptor directory{open_profile(profile)};
            const auto current = read_file(directory.value, "receipt.json", 2'010'000);
            if (current.state == ReadState::unreadable) return false;
            if (current.state == ReadState::loaded) {
                NSDictionary *root = mac_json::object(mac_json::parse(current.bytes, 2'010'000));
                if (format(root, "dtek-monitor-macos-receipt") != ReadState::loaded) return false;
            }
            return replace_file(directory.value, "receipt.json", bytes, fault);
        } catch (...) { return false; }
    }
}
bool clean_logs(const fs::path& profile, fs::file_time_type now, std::size_t reserve_bytes) {
    if (!owned_profile(profile) || reserve_bytes > 5 * 1024 * 1024) return false;
    return log_retention::clean(profile / "logs", now, std::chrono::hours{7 * 24}, 5 * 1024 * 1024 - reserve_bytes);
}
DayReceipt::DayReceipt(const schedule::KyivTimeZone& zone, schedule::FreshnessPolicy policy)
    : zone_(zone), incoming_(policy), retained_(zone, retention(policy)) {}
void DayReceipt::clear(schedule::UtcInstant now) { receipt_.reset(); retained_.clear(now); observed_ = now; }
void DayReceipt::advance(schedule::UtcInstant now) {
    const auto day = zone_.local_date_at(now);
    if ((observed_ && now < *observed_) || (receipt_ && (now < receipt_->received ||
        !day || day != zone_.local_date_at(receipt_->received)))) clear(now);
    observed_ = now;
}
bool DayReceipt::install(Receipt value, const address_draft::Draft& selected, schedule::UtcInstant now, bool restoring) {
    advance(now);
    const auto normalized = address_draft::normalize(selected.street, selected.house);
    if (receipt_ && (!normalized || receipt_->draft != *normalized)) clear(now);
    const auto& address = value.resolution.address;
    if (!normalized || value.draft != *normalized || !address.exact_source_match ||
        !mac_address_search::same_street(mac_json::utf8(mac_json::text(normalized->street)), address.requested_street) ||
        mac_json::utf8(mac_json::text(normalized->house)) != address.requested_house || now < value.received ||
        !zone_.local_date_at(now) || zone_.local_date_at(now) != zone_.local_date_at(value.received)) return false;
    const yasno::Response response{schedule::Failure::none, 200, "application/json", value.body};
    schedule_flow::Flow validation{zone_, incoming_};
    const auto check = validation.select(value.resolution, value.received);
    if (!validation.receive(check, response, value.received, restoring ? value.received : now)) return false;
    // Validation above has no side effects on the previously installed receipt.
    const auto token = retained_.select(value.resolution, value.received);
    if (!retained_.receive(token, response, value.received, now)) return false;
    receipt_ = std::move(value);
    return true;
}
bool DayReceipt::accept(Receipt value, const address_draft::Draft& selected, schedule::UtcInstant now) {
    return install(std::move(value), selected, now, false);
}
bool DayReceipt::restore(Receipt value, const address_draft::Draft& selected, schedule::UtcInstant now) {
    return install(std::move(value), selected, now, true);
}
const std::optional<Receipt>& DayReceipt::saved(schedule::UtcInstant now) { advance(now); return receipt_; }
const popup_schedule::Window& DayReceipt::view(schedule::UtcInstant now) { advance(now); return retained_.view(now); }
schedule::Outcome DayReceipt::outcome(schedule::UtcInstant now) {
    advance(now);
    auto result = retained_.outcome(now);
    if (result.kind == schedule::OutcomeKind::ready && receipt_ && !receipt_->resolution.address.line_explicitly_resolved)
        return {schedule::OutcomeKind::ambiguous_line, std::nullopt};
    return result;
}
std::optional<schedule::Countdown> DayReceipt::estimate(schedule::UtcInstant now) {
    advance(now);
    const auto result = retained_.outcome(now);
    return result.kind == schedule::OutcomeKind::ready ? result.countdown : std::nullopt;
}
void DayReceipt::select_tomorrow(bool value) { retained_.select_tomorrow(value); }
} // namespace mac_profile

namespace mac_profile {
bool append_event(const std::filesystem::path& profile, DiagnosticEvent event,
                  schedule::UtcInstant now, int status, int reason) {
    try {
        const char *name=nullptr;
        switch(event) {
        case DiagnosticEvent::startup:name="startup";break;
        case DiagnosticEvent::address_applied:name="address_applied";break;
        case DiagnosticEvent::lookup_ok:name="lookup_ok";break;
        case DiagnosticEvent::lookup_failed:name="lookup_failed";break;
        case DiagnosticEvent::source_stopped:name="source_stopped";break;
        case DiagnosticEvent::wake:name="wake";break;
        case DiagnosticEvent::clock_changed:name="clock_changed";break;
        case DiagnosticEvent::theme_changed:name="theme_changed";break;
        case DiagnosticEvent::shutdown:name="shutdown";break;
        }
        if(!name || status<0 || status>599 || reason<0 || reason>13 ||
           now.epoch_seconds < -11644473600LL || now.epoch_seconds > 253402300799LL)return false;
        const std::chrono::sys_seconds instant{std::chrono::seconds{now.epoch_seconds}};
        const auto day=std::chrono::floor<std::chrono::days>(instant);
        const std::chrono::year_month_day date{day};
        const std::chrono::hh_mm_ss time{instant-day};
        std::array<char,26> leaf{};
        if(std::snprintf(leaf.data(),leaf.size(),"diagnostic-%04d-%02u-%02u.log",int(date.year()),unsigned(date.month()),unsigned(date.day()))!=25)return false;
        std::array<char,128> line{};
        const auto length=std::snprintf(line.data(),line.size(),"%04d-%02u-%02uT%02lld:%02lld:%02lldZ %s status=%d reason=%d\n",
            int(date.year()),unsigned(date.month()),unsigned(date.day()),
            static_cast<long long>(time.hours().count()),static_cast<long long>(time.minutes().count()),
            static_cast<long long>(time.seconds().count()),name,status,reason);
        if(length<=0 || static_cast<std::size_t>(length)>=line.size())return false;
        Descriptor root{open_profile(profile)};
        if(root.value<0)return false;
        if(::mkdirat(root.value,"logs",0700)!=0 && errno!=EEXIST)return false;
        Descriptor logs{::openat(root.value,"logs",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)};
        if(logs.value<0 || !clean_logs(profile,std::filesystem::file_time_type::clock::now(),static_cast<std::size_t>(length)))return false;
        Descriptor file{::openat(logs.value,leaf.data(),O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW|O_CLOEXEC,0600)};
        struct stat info{};
        if(file.value<0 || ::fstat(file.value,&info)!=0 || !S_ISREG(info.st_mode) || info.st_nlink!=1 ||
           info.st_uid!=::geteuid() || info.st_size<0 ||
           static_cast<std::uintmax_t>(info.st_size)>5*1024*1024-static_cast<std::size_t>(length) || ::fchmod(file.value,0600)!=0)return false;
        std::size_t offset=0;
        while(offset<static_cast<std::size_t>(length)) {
            const auto written=::write(file.value,line.data()+offset,static_cast<std::size_t>(length)-offset);
            if(written<0 && errno==EINTR)continue;
            if(written<=0)return false;
            offset+=static_cast<std::size_t>(written);
        }
        const bool synced=::fsync(file.value)==0;
        const bool closed=::close(file.value)==0; file.value=-1;
        return synced && closed;
    } catch(...) { return false; }
}
} // namespace mac_profile
