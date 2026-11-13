#if !defined(DTEKMONITOR_MAC_TEST_BUILD) || !defined(__APPLE__)
#error Native isolated Mac diagnostic tests required.
#endif
#import <Foundation/Foundation.h>
#include "diagnostics_tests.h"
#include "test_support.h"
#include "../../app/macos/Data/foundation_profile.h"
#include <cstdlib>
#include <algorithm>
#include <fstream>
#include <iterator>
#include <sys/stat.h>

namespace engine_tests {
namespace {
namespace fs=std::filesystem;
std::string diagnostic_read(const fs::path& path) {
    std::ifstream file(path,std::ios::binary); return {std::istreambuf_iterator<char>{file},std::istreambuf_iterator<char>{}};
}
void diagnostic_write(const fs::path& path,std::string_view text) { std::ofstream file(path,std::ios::binary); file<<text; }
void diagnostic_sized(const fs::path& path,std::size_t size) {
    std::ofstream file(path,std::ios::binary); const std::string block(4096,'x');
    while(size) { const auto count=std::min(size,block.size()); file.write(block.data(),static_cast<std::streamsize>(count)); size-=count; }
}
}
bool run_foundation_diagnostics_tests() {
    using mac_profile::DiagnosticEvent;
    using mac_profile::append_event;
    const char *base=std::getenv("DTEKMONITOR_TEST_PROFILE"); if(!base)return false;
    const auto directory=[&]() { const auto path=fs::path{base}/NSUUID.UUID.UUIDString.UTF8String; fs::create_directory(path); return path; };
    const auto now=utc(2026,10,17,5);
    const auto profile=directory(), logs=profile/"logs", leaf=logs/"diagnostic-2026-10-17.log";
    check_result("diagnostics creates only an owned daily file",append_event(profile,DiagnosticEvent::startup,now) && fs::exists(leaf));
    struct stat fileInfo{},dirInfo{}; ::stat(leaf.c_str(),&fileInfo); ::stat(logs.c_str(),&dirInfo);
    check_result("diagnostic files and directory have private modes",(fileInfo.st_mode&0777)==0600 && (dirInfo.st_mode&0777)==0700);
    check_result("diagnostic uses UTC and fixed event codes",diagnostic_read(leaf)=="2026-10-17T05:00:00Z startup status=0 reason=0\n");
    const auto first=diagnostic_read(leaf);
    check_result("append retains the preceding event",append_event(profile,DiagnosticEvent::lookup_failed,now,403,5) && diagnostic_read(leaf).starts_with(first) && diagnostic_read(leaf).find("lookup_failed status=403 reason=5")!=std::string::npos);
    const auto before=diagnostic_read(leaf);
    check_result("unknown event cannot inject text",!append_event(profile,static_cast<DiagnosticEvent>(99),now) && diagnostic_read(leaf)==before);
    check_result("invalid HTTP status is rejected",!append_event(profile,DiagnosticEvent::lookup_failed,now,600) && diagnostic_read(leaf)==before);
    check_result("invalid reason code is rejected",!append_event(profile,DiagnosticEvent::lookup_failed,now,0,14) && diagnostic_read(leaf)==before);
    check_result("out-of-range UTC cannot create a log",!append_event(profile,DiagnosticEvent::startup,schedule::UtcInstant{-11644473601LL}) && !append_event(profile,DiagnosticEvent::startup,schedule::UtcInstant{253402300800LL}) && diagnostic_read(leaf)==before);
    check_result("UTC day changes select another managed file",append_event(profile,DiagnosticEvent::wake,utc(2026,10,18,0)) && fs::exists(logs/"diagnostic-2026-10-18.log"));
    const auto external=directory(); diagnostic_write(external/"marker","KEEP");
    const auto linkedDirectory=directory(); fs::create_directory_symlink(external,linkedDirectory/"logs");
    check_result("symlink log directory is refused",!append_event(linkedDirectory,DiagnosticEvent::startup,now) && diagnostic_read(external/"marker")=="KEEP" && !fs::exists(external/leaf.filename()));
    const auto linkedLeaf=directory(); fs::create_directory(linkedLeaf/"logs"); fs::create_symlink(external/"marker",linkedLeaf/"logs"/leaf.filename());
    check_result("symlink log leaf is refused",!append_event(linkedLeaf,DiagnosticEvent::startup,now) && diagnostic_read(external/"marker")=="KEEP");
    const auto hard=directory(); fs::create_directory(hard/"logs"); fs::create_hard_link(external/"marker",hard/"logs"/leaf.filename());
    check_result("hard-linked log cannot modify another file",!append_event(hard,DiagnosticEvent::startup,now) && diagnostic_read(external/"marker")=="KEEP");
    const auto wrong=directory(); fs::create_directories(wrong/"logs"/leaf.filename());
    check_result("a directory cannot be replaced by a log",!append_event(wrong,DiagnosticEvent::startup,now) && fs::is_directory(wrong/"logs"/leaf.filename()));
    const auto outside=fs::path{base}.parent_path()/std::string{NSUUID.UUID.UUIDString.UTF8String}; fs::create_directory(outside);
    check_result("test profile boundary applies to diagnostics",!append_event(outside,DiagnosticEvent::startup,now) && !fs::exists(outside/"logs"));
    const auto readOnly=directory(); fs::create_directory(readOnly/"logs"); ::chmod((readOnly/"logs").c_str(),0500);
    const bool deniedDirectory=!append_event(readOnly,DiagnosticEvent::startup,now); ::chmod((readOnly/"logs").c_str(),0700);
    check_result("read-only log directory fails without a fallback",deniedDirectory && !fs::exists(readOnly/"logs"/leaf.filename()));
    const auto readOnlyFile=directory(); fs::create_directory(readOnlyFile/"logs"); const auto readOnlyLeaf=readOnlyFile/"logs"/leaf.filename(); diagnostic_write(readOnlyLeaf,"KEEP"); ::chmod(readOnlyLeaf.c_str(),0400);
    const bool deniedFile=!append_event(readOnlyFile,DiagnosticEvent::startup,now); ::chmod(readOnlyLeaf.c_str(),0600);
    check_result("read-only log file is not truncated",deniedFile && diagnostic_read(readOnlyLeaf)=="KEEP");
    const auto old=logs/"diagnostic-2000-01-01.log"; diagnostic_write(old,"old"); fs::last_write_time(old,fs::file_time_type::clock::now()-std::chrono::hours{8*24});
    check_result("append removes managed logs older than seven days",append_event(profile,DiagnosticEvent::wake,now) && !fs::exists(old));
    diagnostic_sized(leaf,5*1024*1024);
    const bool capped=append_event(profile,DiagnosticEvent::lookup_ok,now,200);
    std::uintmax_t total=0; for(const auto& item:fs::directory_iterator(logs))if(item.is_regular_file())total+=item.file_size();
    check_result("append reserves room within the 5 MiB cap",capped && total<=5*1024*1024 && fs::file_size(leaf)<512);
    diagnostic_write(logs/"owner-note.txt","KEEP"); fs::last_write_time(logs/"owner-note.txt",fs::file_time_type::clock::now()-std::chrono::hours{100*24});
    check_result("retention leaves unrelated files untouched",append_event(profile,DiagnosticEvent::theme_changed,now) && diagnostic_read(logs/"owner-note.txt")=="KEEP");
    const std::string settings="{\"format\":\"future-kept-by-diagnostics\",\"address\":\"private-input\"}"; diagnostic_write(profile/"settings.json",settings);
    check_result("diagnostics cannot overwrite future settings",append_event(profile,DiagnosticEvent::shutdown,now) && diagnostic_read(profile/"settings.json")==settings);
    check_result("diagnostics do not contain address or provider payload",diagnostic_read(leaf).find("private-input")==std::string::npos && diagnostic_read(leaf).find("{\"")==std::string::npos && diagnostic_read(leaf).find("shutdown status=0 reason=0")!=std::string::npos);
    return true;
}
} // namespace engine_tests
