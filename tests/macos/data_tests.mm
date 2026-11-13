#if !defined(DTEKMONITOR_MAC_TEST_BUILD) || !defined(__APPLE__)
#error Data tests require the isolated Mac envelope.
#endif
#import <Foundation/Foundation.h>
#include "data_tests.h"
#include "../../app/macos/Data/foundation_json.h"
#include "../../app/macos/Data/foundation_profile.h"
#include "../../app/macos/Time/foundation_kyiv_timezone.h"
#include "test_support.h"
#include <filesystem>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/mount.h>
#include <cstring>

namespace engine_tests {
namespace {
namespace fs = std::filesystem;
template<class Action> bool rejected(Action action) { try { action(); return false; } catch (...) { return true; } }
std::string changed(std::string value, std::string_view from, std::string_view to) {
    const auto at = value.find(from);
    if (at == std::string::npos) throw std::runtime_error("Missing synthetic fixture token");
    value.replace(at, from.size(), to);
    return value;
}
std::string planned() {
    return R"({"2.1":{"updatedOn":"2026-10-17T07:55:00+03:00","today":{"date":"2026-10-17T00:00:00+03:00","status":"ScheduleApplies","slots":[{"start":0,"end":510,"type":"NotPlanned"},{"start":510,"end":720,"type":"Definite"},{"start":720,"end":1440,"type":"NotPlanned"}]},"tomorrow":{"date":"2026-10-18T00:00:00+03:00","status":"WaitingForSchedule","slots":[]}}})";
}
yasno::AddressResolution resolution() {
    const std::string streets = R"([{"id":101,"value":"вул. Тестова"}])";
    const std::string houses = R"([{"id":201,"value":"2-А"}])";
    const std::string group = R"({"group":2,"subgroup":1})";
    return yasno::resolve_address("вул. Тестова", "2-А", {streets,"25","902",{},{}},
        {houses,"25","902","101",{}}, {group,"25","902","101","201"});
}
void write(const fs::path& path, std::string_view bytes) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    file.close();
    if (!file) throw std::runtime_error("Synthetic profile fixture write failed");
}
std::string read(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    return {std::istreambuf_iterator<char>{file}, std::istreambuf_iterator<char>{}};
}
} // namespace

bool run_foundation_data_tests() {
    @autoreleasepool {
        std::cout << std::unitbuf;
        using namespace schedule;
        using mac_profile::ReadState;
        const auto zone = make_foundation_kyiv_time_zone();
        if (!zone) return false;
        const auto now = utc(2026,10,17,5);
        const auto address = resolution();
        const auto body = planned();
        const address_draft::Draft draft{L"вул. Тестова", L"2-А"};
        const auto parsed = [&](std::string_view value) { return yasno::parse_planned_outages(value, address, now); };

        check_result("strict UTF-8 rejects broken continuation", rejected([] { mac_json::parse(std::string{"[\"\xc3\x28\"]",6}); }));
        check_result("UTF-16 body is not silently decoded as UTF-8", rejected([] { mac_json::parse(std::string{"\xff\xfe[\0]\0",6}); }));
        check_result("JSON high surrogate alone rejected", rejected([] { mac_json::parse(R"(["\ud800"])" ); }));
        check_result("JSON low surrogate alone rejected", rejected([] { mac_json::parse(R"(["\udc00"])" ); }));
        check_result("JSON surrogate with wrong second unit rejected", rejected([] { mac_json::parse(R"(["\ud800\u0041"])" ); }));
        check_result("JSON paired surrogate becomes one Mac scalar", mac_json::wide(mac_json::string(mac_json::array(mac_json::parse(R"(["\ud83d\ude00"])") )[0])).size() == 1);
        check_result("escaped literal unicode text remains literal", mac_json::utf8(mac_json::string(mac_json::array(mac_json::parse(R"(["\\ud800"])") )[0])) == "\\ud800");
        check_result("JSON number does not accept boolean", rejected([] { mac_json::number(@YES); }));
        check_result("JSON number does not accept string", rejected([] { mac_json::number(@"12"); }));
        check_result("JSON integer rejects fraction", rejected([] { mac_json::integer(@1.5,100); }));
        check_result("JSON integer rejects negative", rejected([] { mac_json::integer(@(-1),100); }));
        check_result("JSON integer rejects zero ID", rejected([] { mac_json::integer(@0,100); }));
        check_result("JSON slot integer accepts zero", mac_json::integer(@0,1440,true) == 0);
        check_result("JSON safe maximum integer accepted", mac_json::integer(@9007199254740991ULL,9007199254740991ULL) == 9007199254740991ULL);
        check_result("JSON unsafe integer rejected", rejected([] { mac_json::integer(@9007199254740992ULL,9007199254740991ULL); }));
        check_result("JSON infinity rejected", rejected([] { mac_json::number(@(std::numeric_limits<double>::infinity())); }));
        check_result("JSON NaN rejected", rejected([] { mac_json::number(@(std::numeric_limits<double>::quiet_NaN())); }));
        check_result("oversized JSON rejected before decode", rejected([] { mac_json::parse(std::string(2'000'001,' ')); }));

        check_result("draft whitespace normalization matches Windows", address_draft::normalize(L"\u00a0вул. Тестова\u2009",L" 2-А ") == std::optional{draft});
        check_result("draft preserves apostrophe Unicode", address_draft::normalize(L"Лук’янівська",L"1")->street == L"Лук’янівська");
        check_result("draft accepts exactly 120 UTF-16 street units", address_draft::normalize(std::wstring(60,L'\U0001f600'),L"2").has_value());
        check_result("draft rejects 122 UTF-16 street units", !address_draft::normalize(std::wstring(61,L'\U0001f600'),L"2"));
        check_result("draft accepts exactly 24 UTF-16 house units", address_draft::normalize(L"Тест",std::wstring(12,L'\U0001f600')).has_value());
        check_result("draft rejects 26 UTF-16 house units", !address_draft::normalize(L"Тест",std::wstring(13,L'\U0001f600')));
        check_result("draft rejects newline before trimming", !address_draft::normalize(L"\nТест",L"2"));
        check_result("draft rejects C1 controls", !address_draft::normalize(L"Тест\u0085",L"2"));
        check_result("draft rejects surrogate scalar on wchar32", !address_draft::normalize(std::wstring(1,static_cast<wchar_t>(0xd800)),L"2"));
        check_result("draft rejects scalar above Unicode range", !address_draft::normalize(std::wstring(1,static_cast<wchar_t>(0x110000)),L"2"));
        check_result("draft rejects incomplete pair", !address_draft::normalize(L"Тест",L""));
        check_result("draft codec rejects malformed UTF-8", address_draft::read(std::string{"\xc0\xaf",2}) == address_draft::Draft{});
        const auto fields = address_draft::json_fields(draft);
        check_result("draft JSON fragment round trip", fields && address_draft::read("{\"version\":1" + *fields + "}") == draft);
        const address_draft::Draft escaped{L"Тест \"\\\U0001f600",L"2-А"};
        const auto escaped_fields = address_draft::json_fields(escaped);
        check_result("draft quote slash emoji round trip", escaped_fields && address_draft::read("{\"v\":1" + *escaped_fields + "}") == escaped);
        check_result("empty draft codec remains empty", address_draft::json_fields({}).has_value());

        check_result("address binds all reply contexts", address.address.exact_source_match && address.address.street_id == "101" && address.address.house_id == "201");
        check_result("one group does not prove a physical line", address.address.selected_identity == std::optional<ScheduleIdentity>{ScheduleIdentity{"yasno","2.1"}} && !address.address.line_explicitly_resolved);
        check_result("duplicate IDs rejected", rejected([] { yasno::address_choices(R"([{"id":1,"value":"A"},{"id":1,"value":"B"}])"); }));
        check_result("boolean ID rejected", rejected([] { yasno::address_choices(R"([{"id":true,"value":"A"}])"); }));
        check_result("fraction ID rejected", rejected([] { yasno::address_choices(R"([{"id":1.5,"value":"A"}])"); }));
        check_result("canonical labels compare literal Unicode bytes", !yasno::exact_address_choice(R"([{"id":1,"value":"ї"}])","і\u0308"));
        check_result("duplicate canonical label is ambiguous", !yasno::exact_address_choice(R"([{"id":1,"value":"A"},{"id":2,"value":"A"}])","A"));
        check_result("street type aliases preserve unique match", yasno::street_address_choice(R"([{"id":1,"value":"вул. Тестова"}])","ТЕСТОВА").has_value());
        check_result("street types do not collapse ambiguity", !yasno::street_address_choice(R"([{"id":1,"value":"вул. Тестова"},{"id":2,"value":"пров. Тестова"}])","Тестова"));
        const std::string streets = R"([{"id":101,"value":"вул. Тестова"}])", houses = R"([{"id":201,"value":"2-А"}])";
        check_result("wrong DSO cannot resolve", !yasno::resolve_address("вул. Тестова","2-А",{streets,"25","999",{},{}},{houses,"25","902","101",{}},{R"({"group":2,"subgroup":1})","25","902","101","201"}).address.exact_source_match);
        check_result("wrong street request cannot resolve", !yasno::resolve_address("вул. Тестова","2-А",{streets,"25","902",{},{}},{houses,"25","902","102",{}},{R"({"group":2,"subgroup":1})","25","902","101","201"}).address.exact_source_match);
        check_result("extra group field rejects schema", yasno::resolve_address("вул. Тестова","2-А",{streets,"25","902",{},{}},{houses,"25","902","101",{}},{R"({"group":2,"subgroup":1,"line":1})","25","902","101","201"}).parse_state == ParseState::unsupported_schema);
        check_result("boolean subgroup rejects schema", yasno::resolve_address("вул. Тестова","2-А",{streets,"25","902",{},{}},{houses,"25","902","101",{}},{R"({"group":2,"subgroup":true})","25","902","101","201"}).parse_state == ParseState::unsupported_schema);

        const auto good = parsed(body);
        check_result("planned JSON produces two dated days", good.parse_state == ParseState::valid && good.days.size() == 2);
        check_result("planned JSON source stamp retained", good.source_updated_at_utc == now - 300);
        check_result("planned definite interval maps through named Kyiv", good.days.size() == 2 && good.days[0].outages.size() == 1 && good.days[0].outages[0].starts_at_utc == utc(2026,10,17,5,30) && good.days[0].outages[0].ends_at_utc == utc(2026,10,17,9));
        check_result("unpublished tomorrow not verified", good.days.size() == 2 && !good.days[1].interval_semantics_verified);
        check_result("unknown status rejects schema", parsed(changed(body,"ScheduleApplies","NewStatus")).parse_state == ParseState::unsupported_schema);
        check_result("unknown slot rejects schema", parsed(changed(body,"Definite","Unknown")).parse_state == ParseState::unsupported_schema);
        check_result("uncertain slots never become definite proof", !parsed(changed(body,"Definite","Possible")).days[0].interval_semantics_verified);
        check_result("slot gap rejects schema", parsed(changed(body,"\"start\":510","\"start\":511")).parse_state == ParseState::unsupported_schema);
        check_result("slot overlap rejects schema", parsed(changed(body,"\"start\":510","\"start\":509")).parse_state == ParseState::unsupported_schema);
        check_result("fraction slot rejects schema", parsed(changed(body,"\"end\":510","\"end\":510.5")).parse_state == ParseState::unsupported_schema);
        check_result("boolean slot rejects schema", parsed(changed(body,"\"start\":0","\"start\":false")).parse_state == ParseState::unsupported_schema);
        check_result("wrong Kyiv day offset rejects schema", parsed(changed(body,"2026-10-17T00:00:00+03:00","2026-10-17T00:00:00+02:00")).parse_state == ParseState::unsupported_schema);
        check_result("nonconsecutive tomorrow rejects schema", parsed(changed(body,"2026-10-18T00:00:00+03:00","2026-10-19T00:00:00+03:00")).parse_state == ParseState::unsupported_schema);
        check_result("invalid calendar day rejects schema", parsed(changed(body,"2026-10-17T00:00:00+03:00","2026-02-30T00:00:00+02:00")).parse_state == ParseState::unsupported_schema);
        check_result("HTML is not schema", parsed("<html>test</html>").parse_state == ParseState::unsupported_schema);
        check_result("missing group rejects schema", parsed(changed(body,"\"2.1\"","\"3.1\"")).parse_state == ParseState::unsupported_schema);
        const auto response = [&](int status,std::string_view type,std::string_view bytes) { return yasno::parse_response({Failure::none,status,type,bytes},address,now); };
        check_result("HTTP 200 JSON valid receipt", response(200,"Application/JSON; charset=utf-8",body).fetched_at_utc == now);
        check_result("HTTP 304 never refreshes receipt", response(304,"application/json",body).fetched_at_utc == UtcInstant{});
        check_result("HTTP 204 reports unexpected body", response(204,"application/json",body).failure == Failure::unexpected_body);
        check_result("HTML MIME cannot become receipt", response(200,"text/html",body).failure == Failure::unexpected_body);
        check_result("malformed JSON cannot become receipt", response(200,"application/json","{").failure == Failure::unexpected_body);
        check_result("unsupported schema cannot stamp a successful fetch", response(200,"application/json","{}").fetched_at_utc == UtcInstant{});

        const char *profile_env = std::getenv("DTEKMONITOR_TEST_PROFILE");
        if (!profile_env) return false;
        const fs::path parent{profile_env};
        const auto root = parent / ("data-" + mac_json::utf8(NSUUID.UUID.UUIDString));
        fs::create_directories(root / fs::path{mac_json::utf8(@"дані-é")});
        const auto profile = fs::canonical(root / fs::path{mac_json::utf8(@"дані-é")});
        struct statfs volume{};
        const bool volume_read = ::statfs(profile.c_str(),&volume) == 0;
        check_result("native profile filesystem is APFS", volume_read && std::strcmp(volume.f_fstypename,"apfs") == 0);
        check_result("missing settings read does not create a file", mac_profile::load_settings(profile).state == ReadState::missing && !fs::exists(profile/"settings.json"));
        const mac_profile::Settings settings{draft,"dark",true,true,-420,700,2};
        write(profile/"settings.json",R"({"format":"dtek-monitor-macos-settings","version":1,"draftStreet":"вул. Тестова","draftHouse":"2-А","theme":"dark"})");
        const auto legacy=mac_profile::load_settings(profile);
        check_result("legacy settings load and Unicode path settings save", legacy.state==ReadState::loaded && legacy.value.draft==draft &&
            !legacy.value.floating_visible && !legacy.value.floating_positioned && mac_profile::save_settings(profile,settings));
        check_result("settings and floating window position round trip", mac_profile::load_settings(profile).value == settings);
        const auto original_settings = read(profile/"settings.json");
        for (const auto fault : {mac_profile::WriteFault::partial_write,mac_profile::WriteFault::close_error,mac_profile::WriteFault::replace_error}) {
            check_result("failed atomic write preserves original settings", !mac_profile::save_settings(profile,{draft,"light"},fault) && read(profile/"settings.json") == original_settings);
        }
        bool temporary_left = false;
        for (const auto& entry : fs::directory_iterator(profile)) if (entry.path().extension() == ".tmp") temporary_left = true;
        check_result("failed writes clean only their owned temporary files", !temporary_left);
        write(profile/"settings.json",changed(original_settings,"\"version\":1","\"version\":2"));
        const auto future = read(profile/"settings.json");
        check_result("future settings schema reported", mac_profile::load_settings(profile).state == ReadState::future_schema);
        check_result("future settings never overwritten", !mac_profile::save_settings(profile,settings) && read(profile/"settings.json") == future);
        write(profile/"settings.json","not json");
        check_result("unreadable JSON settings never overwritten", !mac_profile::save_settings(profile,settings) && read(profile/"settings.json") == "not json");
        write(profile/"settings.json",R"({"version":1,"draftStreet":"Windows","draftHouse":"2","theme":"dark"})");
        check_result("Windows settings are not silently imported", mac_profile::load_settings(profile).state == ReadState::unreadable && !mac_profile::save_settings(profile,settings));
        write(profile/"settings.json",original_settings);
        ::chmod(profile.c_str(),0500);
        const bool denied = !mac_profile::save_settings(profile,{draft,"light"});
        ::chmod(profile.c_str(),0700);
        check_result("native directory write denial preserves settings", denied && read(profile/"settings.json") == original_settings);
        ::chmod((profile/"settings.json").c_str(),0000);
        const auto unreadable = mac_profile::load_settings(profile).state;
        const bool protected_file = !mac_profile::save_settings(profile,settings);
        ::chmod((profile/"settings.json").c_str(),0600);
        check_result("native read denial is not a missing profile", unreadable == ReadState::unreadable && protected_file);
        fs::create_directory_symlink(profile,root/"alias");
        check_result("symlink profile rejected", !mac_profile::save_settings(root/"alias",settings));
        fs::rename(profile/"settings.json",profile/"settings-owned.json");
        fs::create_symlink(profile/"settings-owned.json",profile/"settings.json");
        check_result("symlink settings file rejected without target changes", !mac_profile::save_settings(profile,settings) && read(profile/"settings-owned.json") == original_settings);
        fs::remove(profile/"settings.json");
        fs::rename(profile/"settings-owned.json",profile/"settings.json");

        const mac_profile::Receipt saved{draft,address,body,now};
        auto persisted = saved;
        persisted.resolution.address.line_explicitly_resolved = true; // Synthetic proof must not survive disk.
        check_result("receipt persists only in isolated profile", mac_profile::save_receipt(profile,persisted));
        const auto restored = mac_profile::load_receipt(profile);
        check_result("receipt preserves original received timestamp", restored && restored->received == now && restored->draft == draft);
        check_result("receipt does not manufacture physical-line proof", restored && !restored->resolution.address.line_explicitly_resolved);
        check_result("receipt retains source timestamp", restored && parsed(restored->body).source_updated_at_utc == good.source_updated_at_utc);
        const auto original_receipt = read(profile/"receipt.json");
        write(profile/"receipt.json",changed(original_receipt,"\"version\":1","\"version\":2"));
        const auto future_receipt = read(profile/"receipt.json");
        check_result("future receipt schema never overwritten", !mac_profile::load_receipt(profile) && !mac_profile::save_receipt(profile,saved) && read(profile/"receipt.json") == future_receipt);
        write(profile/"receipt.json",original_receipt);
        mac_profile::DayReceipt cache{*zone};
        check_result("fresh receipt installs", cache.accept(saved,draft,now) && cache.view(now).today().has_value());
        check_result("group estimate remains distinct from physical-line proof", cache.outcome(now).kind == OutcomeKind::ambiguous_line && cache.estimate(now).has_value());
        check_result("unconfirmed tomorrow cannot be selected", !cache.view(now).has_tomorrow());
        check_result("validated receipt retained past incoming age limit", cache.view(now+3601).today().has_value() && cache.saved(now+3601)->received == now);
        auto invalid = saved; invalid.body = "{}"; invalid.received = now+3602;
        check_result("failed refresh retains original today and stamps", !cache.accept(invalid,draft,now+3602) && cache.view(now+3602).today().has_value() && cache.saved(now+3602)->received == now);
        mac_profile::DayReceipt cold{*zone};
        check_result("same-day disk receipt restores with original stamp", restored && cold.restore(*restored,draft,now+3601) && cold.saved(now+3601)->received == now);
        check_result("receipt cannot restore for another address", restored && !cold.restore(*restored,{L"вул. Інша",L"2-А"},now+3601) && !cold.view(now+3601).today());
        mac_profile::DayReceipt stale{*zone};
        check_result("new incoming receipt older than 3600 rejected", !stale.accept(saved,draft,now+3601));
        auto old_source = saved; old_source.body = changed(body,"2026-10-17T07:55:00+03:00","2026-10-15T07:59:59+03:00");
        check_result("incoming source older than 48 hours rejected", !stale.accept(old_source,draft,now));
        auto future_source = saved; future_source.body = changed(body,"2026-10-17T07:55:00+03:00","2026-10-17T08:05:01+03:00");
        check_result("incoming source beyond 300 seconds skew rejected", !stale.accept(future_source,draft,now));
        auto replacement = saved; replacement.received = now+3603;
        replacement.body = changed(body,"\"status\":\"ScheduleApplies\"","\"status\":\"EmergencyShutdowns\"");
        check_result("new successful emergency replaces prior receipt", cache.accept(replacement,draft,now+3603) && cache.outcome(now+3603).kind == OutcomeKind::emergency && cache.saved(now+3603)->received == now+3603);
        const auto midnight = utc(2026,10,17,21);
        check_result("receipt expires at Kyiv midnight", !cache.saved(midnight) && !cache.view(midnight).today());
        check_result("previous-day disk receipt cannot restore", restored && !cold.restore(*restored,draft,midnight));
        mac_profile::DayReceipt rollback{*zone};
        rollback.accept(saved,draft,now); rollback.view(now+10);
        check_result("clock rollback discards receipt", !rollback.saved(now+9) && !rollback.view(now+9).today());
        check_result("clock forward cannot revive discarded receipt", !rollback.saved(now+11) && !rollback.view(now+11).today());
        auto tomorrow = saved;
        tomorrow.body = changed(body,R"("status":"WaitingForSchedule","slots":[])",R"("status":"ScheduleApplies","slots":[{"start":0,"end":1440,"type":"NotPlanned"}])");
        mac_profile::DayReceipt published{*zone};
        check_result("only published tomorrow becomes selectable", published.accept(tomorrow,draft,now) && published.view(now).has_tomorrow());
        published.select_tomorrow(true);
        check_result("published tomorrow selection works", published.view(now).viewing_tomorrow());

        fs::create_directory(profile/"logs");
        const auto file_now = fs::file_time_type::clock::now();
        write(profile/"logs"/"diagnostic-2026-10-01.log","old");
        fs::last_write_time(profile/"logs"/"diagnostic-2026-10-01.log",file_now-std::chrono::hours{169});
        write(profile/"logs"/"diagnostic-2026-10-17.log",std::string(3*1024*1024,'x'));
        fs::last_write_time(profile/"logs"/"diagnostic-2026-10-17.log",file_now-std::chrono::hours{1});
        write(profile/"logs"/"diagnostic-2026-10-18.log",std::string(3*1024*1024,'x'));
        fs::last_write_time(profile/"logs"/"diagnostic-2026-10-18.log",file_now);
        write(profile/"logs"/fs::path{mac_json::utf8(@"примітка.log")},"keep");
        fs::create_symlink(profile/"settings.json",profile/"logs"/"diagnostic-2026-10-19.log");
        check_result("native log cleanup succeeds", mac_profile::clean_logs(profile,file_now));
        check_result("logs expire after seven days", !fs::exists(profile/"logs"/"diagnostic-2026-10-01.log"));
        check_result("logs respect five MiB cap", !fs::exists(profile/"logs"/"diagnostic-2026-10-17.log") && fs::exists(profile/"logs"/"diagnostic-2026-10-18.log"));
        check_result("log cleanup preserves unrelated Unicode file", read(profile/"logs"/fs::path{mac_json::utf8(@"примітка.log")}) == "keep");
        check_result("log cleanup never follows symlinks", fs::is_symlink(fs::symlink_status(profile/"logs"/"diagnostic-2026-10-19.log")) && read(profile/"settings.json") == original_settings);
        write(parent/"m4-restart-profile.txt",profile.native());
        return true;
    }
}
bool run_foundation_restart_tests() {
    @autoreleasepool {
        std::cout << std::unitbuf;
        const char *base = std::getenv("DTEKMONITOR_TEST_PROFILE");
        if (!base) return false;
        const fs::path profile{read(fs::path{base}/"m4-restart-profile.txt")};
        std::error_code error;
        const auto canonical = fs::canonical(profile,error);
        if (error || !profile.is_absolute() || canonical != profile) return false;
        const auto relative = canonical.lexically_relative(fs::path{base});
        if (relative.empty() || *relative.begin() == "..") return false;
        const auto zone = schedule::make_foundation_kyiv_time_zone();
        if (!zone) return false;
        const auto settings_bytes = read(profile/"settings.json"), receipt_bytes = read(profile/"receipt.json");
        const address_draft::Draft draft{L"вул. Тестова",L"2-А"};
        const auto settings = mac_profile::load_settings(profile);
        const auto saved = mac_profile::load_receipt(profile);
        const auto now = utc(2026,10,17,5);
        check_result("fresh process loads settings", settings.state == mac_profile::ReadState::loaded && settings.value.draft == draft && settings.value.theme == "dark");
        check_result("fresh process loads original receipt/source stamps", saved && saved->received == now && yasno::parse_planned_outages(saved->body,saved->resolution,now).source_updated_at_utc == now-300);
        mac_profile::DayReceipt cache{*zone};
        check_result("fresh process restores the validated same-day receipt", saved && cache.restore(*saved,draft,now+3601) && cache.view(now+3601).today().has_value());
        check_result("fresh process enforces original midnight expiry", !cache.saved(utc(2026,10,17,21)));
        check_result("fresh process read never relabels disk timestamps", read(profile/"settings.json") == settings_bytes && read(profile/"receipt.json") == receipt_bytes);
        return true;
    }
}
} // namespace engine_tests
