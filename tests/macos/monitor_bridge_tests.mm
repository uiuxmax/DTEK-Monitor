#if !defined(DTEKMONITOR_MAC_TEST_BUILD) || !defined(__APPLE__)
#error Isolated native Mac tests required.
#endif
#import "../../app/macos/Session/MonitorBridge.h"
#include "monitor_bridge_tests.h"
#include "test_support.h"
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>

namespace engine_tests {
namespace {
const char *streets=R"([{"id":101,"value":"вул. Тестова"}])";
const char *houses=R"([{"id":201,"value":"2-А"}])";
const char *group=R"({"group":2,"subgroup":1})";
const char *planned=R"({"2.1":{"updatedOn":"2026-10-17T07:55:00+03:00","today":{"date":"2026-10-17T00:00:00+03:00","status":"ScheduleApplies","slots":[{"start":0,"end":510,"type":"NotPlanned"},{"start":510,"end":720,"type":"Definite"},{"start":720,"end":1440,"type":"NotPlanned"}]},"tomorrow":{"date":"2026-10-18T00:00:00+03:00","status":"WaitingForSchedule","slots":[]}}})";
NSData *data(const char *bytes) { return [[NSString stringWithUTF8String:bytes] dataUsingEncoding:NSUTF8StringEncoding]; }
NSDictionary *answer(NSDictionary *request,int64_t now) {
    NSString *kind=request[@"kind"];
    const auto bytes=[kind isEqual:@"streets"] ? streets : [kind isEqual:@"houses"] ? houses : [kind isEqual:@"group"] ? group : planned;
    return @{@"token":request[@"token"],@"error":@"none",@"status":@200,@"mime":@"application/json",@"body":data(bytes),@"received":@(now)};
}
std::string read(const std::filesystem::path& path) {
    std::ifstream file(path,std::ios::binary); return {std::istreambuf_iterator<char>{file},std::istreambuf_iterator<char>{}};
}
}
bool run_monitor_bridge_tests() {
    @autoreleasepool {
        const char *base=std::getenv("DTEKMONITOR_TEST_PROFILE");
        if(!base)return false;
        const auto profile=std::filesystem::path{base}/std::string{NSUUID.UUID.UUIDString.UTF8String};
        std::filesystem::create_directory(profile);
        NSString *path=[NSString stringWithUTF8String:profile.c_str()];
        const auto now=utc(2026,10,17,5).epoch_seconds;
        check_result("bridge normalizes with the M4 address validator",[DMMonitorEngine normalizeStreet:@"  вул. Тестова  " house:@" 2-А "]!=nil);
        check_result("bridge rejects missing house",[DMMonitorEngine normalizeStreet:@"вул. Тестова" house:@""]==nil);
        check_result("bridge rejects control characters",[DMMonitorEngine normalizeStreet:@"вул.\nТестова" house:@"2-А"]==nil);
        check_result("bridge query uses source matcher rules",[[DMMonitorEngine streetQuery:@"ВУЛ. ТЕСТОВА"] isEqual:@"тестова"]);
        DMMonitorEngine *engine=[[DMMonitorEngine alloc] initWithProfile:path epoch:now];
        NSDictionary *initial=[engine snapshotAtEpoch:now];
        check_result("new profile has no fabricated schedule",![initial[@"forecast"] boolValue] && [initial[@"street"] length]==0);
        check_result("theme defaults to system",[initial[@"theme"] isEqual:@"system"]);
        check_result("valid address saves to isolated profile",[engine selectStreet:@"вул. Тестова" house:@"2-А" epoch:now] && std::filesystem::exists(profile/"settings.json"));
        check_result("theme saves through atomic settings backend",[engine setTheme:@"dark"] && [[engine snapshotAtEpoch:now][@"theme"] isEqual:@"dark"]);
        check_result("invalid theme cannot change saved value",![engine setTheme:@"invalid"] && [[engine snapshotAtEpoch:now][@"theme"] isEqual:@"dark"]);
        __block int calls=0;
        DMLookupOperation *operation=[[DMLookupOperation alloc] initWithStreet:@"вул. Тестова" house:@"2-А" token:42 suggestions:NO houseSuggestions:NO];
        DMLookupReply *reply=[operation performWithTransport:^NSDictionary *(NSDictionary *request) { ++calls; return answer(request,now); }];
        check_result("bridge executes the four-stage worker",calls==4 && reply.token==42 && [reply.metadata[@"failure"] isEqual:@"none"]);
        check_result("bridge receipt is accepted by the existing cache",[engine acceptReply:reply epoch:now]);
        NSDictionary *ready=[engine snapshotAtEpoch:now];
        check_result("bridge exposes forecast and complement intervals",[ready[@"forecast"] boolValue] && [ready[@"intervals"] count]==3);
        check_result("bridge preserves exact daily outage duration",[ready[@"totalOutageMinutes"] intValue]==210);
        check_result("bridge exposes an estimated local countdown",[ready[@"countdown"] length]>0);
        check_result("unpublished tomorrow remains disabled",![ready[@"tomorrowAvailable"] boolValue]);
        check_result("original receipt time is preserved",[ready[@"received"] longLongValue]==now);
        check_result("receipt persists only in the supplied profile",std::filesystem::exists(profile/"receipt.json"));
        DMLookupReply *second=[operation performWithTransport:^NSDictionary *(NSDictionary *request) { ++calls; return answer(request,now); }];
        check_result("operation cannot execute twice",calls==4 && ![second.metadata[@"failure"] isEqual:@"none"]);
        DMLookupOperation *cancelled=[[DMLookupOperation alloc] initWithStreet:@"вул. Тестова" house:@"2-А" token:43 suggestions:NO houseSuggestions:NO];
        [cancelled cancel];
        DMLookupReply *cancelReply=[cancelled performWithTransport:^NSDictionary *(NSDictionary *request) { ++calls; return answer(request,now); }];
        check_result("pre-cancelled bridge starts no GET",calls==4 && [cancelReply.metadata[@"failure"] isEqual:@"cancelled"]);
        DMLookupOperation *forbidden=[[DMLookupOperation alloc] initWithStreet:@"вул. Тестова" house:@"2-А" token:44 suggestions:NO houseSuggestions:NO];
        DMLookupReply *blocked=[forbidden performWithTransport:^NSDictionary *(NSDictionary *request) {
            return @{@"token":request[@"token"],@"error":@"http",@"status":@429,@"mime":@"",@"body":NSData.data,@"received":NSNull.null};
        }];
        check_result("bridge preserves source stop metadata",[blocked.metadata[@"failure"] isEqual:@"forbidden"] && [blocked.metadata[@"stages"][0][@"status"] intValue]==429);
        check_result("blocked lookup cannot replace the receipt",![engine acceptReply:blocked epoch:now+1] && [[engine snapshotAtEpoch:now+1][@"forecast"] boolValue]);
        DMMonitorEngine *restarted=[[DMMonitorEngine alloc] initWithProfile:path epoch:now+2];
        NSDictionary *restored=[restarted snapshotAtEpoch:now+2];
        check_result("bridge restart restores address and theme",[restored[@"street"] isEqual:@"вул. Тестова"] && [restored[@"theme"] isEqual:@"dark"]);
        check_result("bridge restart keeps the original receipt stamp",[restored[@"forecast"] boolValue] && [restored[@"received"] longLongValue]==now);
        check_result("Kyiv midnight expires the restored receipt",![[restarted snapshotAtEpoch:utc(2026,10,17,21).epoch_seconds][@"forecast"] boolValue]);
        std::filesystem::rename(profile/"receipt.json",profile/"receipt-owned.json");
        std::filesystem::create_symlink(profile/"receipt-owned.json",profile/"receipt.json");
        const bool protectedReceipt=![engine selectStreet:@"вул. Інша" house:@"2-А" epoch:now+2] &&
            std::filesystem::exists(profile/"receipt-owned.json") && [[engine snapshotAtEpoch:now+2][@"storageWarning"] boolValue];
        std::filesystem::remove(profile/"receipt.json");
        std::filesystem::rename(profile/"receipt-owned.json",profile/"receipt.json");
        check_result("address change refuses symlink and clears the prior receipt",protectedReceipt && [engine selectStreet:@"вул. Інша" house:@"2-А" epoch:now+2] && ![[engine snapshotAtEpoch:now+2][@"forecast"] boolValue] && !std::filesystem::exists(profile/"receipt.json"));
        const auto settingsBefore=read(profile/"settings.json");
        check_result("invalid address cannot overwrite settings",![engine selectStreet:@"" house:@"" epoch:now+2] && read(profile/"settings.json")==settingsBefore);
        return true;
    }
}
} // namespace engine_tests
