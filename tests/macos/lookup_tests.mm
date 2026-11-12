#if !defined(DTEKMONITOR_MAC_TEST_BUILD) || !defined(__APPLE__)
#error Isolated native Mac tests required.
#endif
#include "lookup_tests.h"
#include "../../app/yasno_lookup.h"
#include "test_support.h"
#include <array>
#include <stdexcept>

namespace engine_tests {
namespace {
using namespace yasno;
using namespace yasno::https;
using namespace yasno::lookup;
const LookupRequest selected{7,"вул. Тестова","2-А"};
const std::array<std::string,4> bodies{
    R"([{"id":101,"value":"вул. Тестова"}])",
    R"([{"id":201,"value":"2-А"}])",
    R"({"group":2,"subgroup":1})",
    R"({"2.1":{"updatedOn":"2026-10-17T07:55:00+03:00","today":{"date":"2026-10-17T00:00:00+03:00","status":"ScheduleApplies","slots":[{"start":0,"end":1440,"type":"NotPlanned"}]},"tomorrow":{"date":"2026-10-18T00:00:00+03:00","status":"WaitingForSchedule","slots":[]}}})"
};
Completion reply(Request request, unsigned stage) {
    Completion value{std::move(request)};
    value.status=200; value.content_type="application/json"; value.body=bodies.at(stage);
    value.received_at=utc(2026,10,17,5)+static_cast<int>(stage);
    return value;
}
} // namespace
bool run_foundation_lookup_tests() {
    std::vector<Request> requests;
    auto success=lookup_once(selected,[&](Request request,std::stop_token) {
        requests.push_back(request); return reply(std::move(request),static_cast<unsigned>(requests.size()-1));
    });
    check_result("lookup runs exactly four ordered resources", success.failure==LookupFailure::none && requests.size()==4 &&
        requests[0].resource.kind==ResourceKind::streets && requests[1].resource.kind==ResourceKind::houses &&
        requests[2].resource.kind==ResourceKind::group && requests[3].resource.kind==ResourceKind::planned_outages);
    if (requests.size()!=4 || !success.schedule) return false;
    check_result("lookup query uses existing Ukrainian street rules", requests[0].resource.query_utf8=="тестова");
    check_result("lookup house and group bind chosen IDs", requests[1].resource.street_id=="101" &&
        requests[1].resource.query_utf8=="2-А" && requests[2].resource.street_id=="101" && requests[2].resource.house_id=="201");
    check_result("lookup preserves token and canonical address", success.selection==7 && success.resolution.address.exact_source_match &&
        success.resolution.address.requested_street=="вул. Тестова" && success.resolution.address.requested_house=="2-А");
    check_result("lookup group never invents physical line proof", !success.resolution.address.line_explicitly_resolved &&
        success.resolution.address.selected_identity==schedule::ScheduleIdentity{"yasno","2.1"});
    check_result("lookup copies resolved context to schedule request", requests[3].resolution.address==success.resolution.address);
    check_result("lookup preserves the original schedule receipt", success.schedule && success.schedule->received_at==utc(2026,10,17,5)+3);
    const auto parsed=yasno::parse_response(success.schedule->response(),success.resolution,*success.schedule->received_at);
    check_result("lookup receipt validates through the existing Foundation parser", parsed.parse_state==schedule::ParseState::valid &&
        parsed.failure==schedule::Failure::none && parsed.days.size()==2 && parsed.fetched_at_utc==*success.schedule->received_at);
    for (const auto& request:requests) {
        check_result("each stage has an independent full attempt budget",request.limits.body_bytes==2'000'000 && request.limits.total_ms==30'000);
        check_result("each stage resource is fixed and encodable",resource_path(request.resource).has_value());
    }
    for (unsigned stage=0; stage<4; ++stage) {
        for (const int status:{403,429}) {
            unsigned calls=0;
            auto result=lookup_once(selected,[&](Request request,std::stop_token) {
                auto value=reply(std::move(request),calls++);
                if (calls==stage+1) { value.status=status; value.error=Error::http; value.body.clear(); value.received_at.reset(); }
                return value;
            });
            check_result("403/429 stops the remaining lookup chain", result.failure==LookupFailure::forbidden && calls==stage+1 &&
                !result.schedule && result.stages.back().status==status);
        }
        unsigned calls=0;
        auto timeout=lookup_once(selected,[&](Request request,std::stop_token) {
            auto value=reply(std::move(request),calls++);
            if (calls==stage+1) { value.error=Error::timeout; value.body.clear(); value.received_at.reset(); }
            return value;
        });
        check_result("timeout cannot advance to another stage",timeout.failure==LookupFailure::transport && calls==stage+1 && !timeout.schedule);
        calls=0; std::stop_source stop;
        auto cancelled=lookup_once(selected,[&](Request request,std::stop_token token) {
            auto value=reply(std::move(request),calls++);
            if (calls==stage+1) stop.request_stop();
            check_result("stage receives the caller cancellation state", token.stop_requested()==stop.stop_requested());
            return value;
        },stop.get_token());
        check_result("cancellation after a stage prevents the next GET",cancelled.failure==LookupFailure::cancelled && calls==stage+1 && !cancelled.schedule);
        calls=0;
        auto raised=lookup_once(selected,[&](Request request,std::stop_token) {
            if (calls++==stage) throw std::runtime_error("synthetic transport failure");
            return reply(std::move(request),calls-1);
        });
        check_result("transport exception stops the chain",raised.failure==LookupFailure::transport && calls==stage+1 && !raised.schedule);
    }
    const std::array<std::function<void(Request&)>,8> corrupt{
        [](Request& r){++r.token;}, [](Request& r){r.resource.kind=static_cast<ResourceKind>(99);},
        [](Request& r){r.resource.query_utf8+="x";}, [](Request& r){r.resource.street_id="999";},
        [](Request& r){r.resource.house_id="999";}, [](Request& r){r.resolution.address.house_id="999";},
        [](Request& r){r.limits.body_bytes=1;}, [](Request& r){r.limits.total_ms=1;}
    };
    for (unsigned stage=0;stage<4;++stage) for (const auto& mutate:corrupt) {
        unsigned calls=0;
        auto result=lookup_once(selected,[&](Request request,std::stop_token) {
            auto value=reply(std::move(request),calls++); if(calls==stage+1) mutate(value.request); return value;
        });
        check_result("a reply cannot relabel resource/token/address/budget",result.failure==LookupFailure::address_mismatch && calls==stage+1 && !result.schedule);
    }
    unsigned calls=0;
    auto none=lookup_once({0,"вул. Тестова","2-А"},[&](Request r,std::stop_token){++calls;return reply(std::move(r),0);});
    check_result("zero selection performs no IO",none.failure==LookupFailure::schema && calls==0);
    check_result("missing getter performs no IO",lookup_once(selected,{}).failure==LookupFailure::schema);
    std::stop_source stopped; stopped.request_stop();
    auto early=lookup_once(selected,[&](Request r,std::stop_token){++calls;return reply(std::move(r),0);},stopped.get_token());
    check_result("pre-cancelled lookup performs no IO",early.failure==LookupFailure::cancelled && calls==0);
    auto invalid=lookup_once({7,std::string{"\xc3\x28",2},"2"},[&](Request r,std::stop_token){++calls;return reply(std::move(r),0);});
    check_result("invalid UTF-8 query fails before IO",invalid.failure==LookupFailure::schema && calls==0);
    calls=0;
    auto suggestions=lookup_once({8,"ТЕС",{},true},[&](Request request,std::stop_token){++calls;return reply(std::move(request),0);});
    check_result("suggestions use one street resource only",suggestions.failure==LookupFailure::none && suggestions.suggestions.size()==1 && calls==1 && !suggestions.schedule);
    return true;
}
} // namespace engine_tests
