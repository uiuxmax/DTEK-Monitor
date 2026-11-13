#import "MonitorBridge.h"
#include "../Data/foundation_yasno_lookup.h"
#include "../Data/foundation_profile.h"
#include "../Data/foundation_json.h"
#include "../Data/foundation_address_search.h"
#include "../Time/foundation_kyiv_timezone.h"
#include <charconv>
#include <cmath>
#include <memory>
#include <stdexcept>

namespace {
using namespace yasno;
using namespace yasno::lookup;
using namespace yasno::https;
NSString *text(std::string_view value) { return mac_json::text(value); }
NSString *wide_text(std::wstring_view value) { return mac_json::text(value); }
NSString *resource_name(ResourceKind value) {
    switch(value) {
    case ResourceKind::streets:return @"streets"; case ResourceKind::houses:return @"houses";
    case ResourceKind::group:return @"group"; case ResourceKind::planned_outages:return @"planned";
    }
    return @"invalid";
}
NSString *failure_name(LookupFailure value) {
    switch(value) {
    case LookupFailure::none:return @"none"; case LookupFailure::transport:return @"transport";
    case LookupFailure::address_mismatch:return @"address_mismatch"; case LookupFailure::schema:return @"schema";
    case LookupFailure::cancelled:return @"cancelled"; case LookupFailure::forbidden:return @"forbidden";
    }
    return @"schema";
}
Error error_code(NSString *value) {
    const auto code=mac_json::utf8(value);
    if(code=="none")return Error::none; if(code=="dns")return Error::dns; if(code=="tls")return Error::tls;
    if(code=="http")return Error::http; if(code=="timeout")return Error::timeout; if(code=="cancelled")return Error::cancelled;
    if(code=="connection")return Error::connection;
    if(code=="body_too_large")return Error::body_too_large; if(code=="incomplete_body")return Error::incomplete_body;
    if(code=="cleanup")return Error::cleanup; if(code=="invalid_request")return Error::invalid_request;
    return Error::invalid_response;
}
std::uint64_t token_number(id value) {
    mac_json::number(value); // Reject booleans/non-finite values before decimal conversion.
    const auto bytes=mac_json::utf8([(NSNumber *)value stringValue]);
    std::uint64_t token=0;
    const auto result=std::from_chars(bytes.data(),bytes.data()+bytes.size(),token);
    if(result.ec!=std::errc{} || result.ptr!=bytes.data()+bytes.size())throw std::invalid_argument("Invalid token");
    return token;
}
struct OperationState {
    LookupRequest request;
    StopSource cancellation;
    std::atomic<bool> started{false};
    bool valid=false;
};
struct EngineState {
    std::filesystem::path profile;
    mac_profile::Settings settings;
    bool storage_warning=false;
    std::unique_ptr<schedule::KyivTimeZone> zone=schedule::make_foundation_kyiv_time_zone();
    std::unique_ptr<mac_profile::DayReceipt> receipt;
    explicit EngineState(NSString *path,schedule::UtcInstant now) : profile(mac_json::utf8(path)) {
        const auto loaded=mac_profile::load_settings(profile);
        settings=loaded.value;
        storage_warning=loaded.state==mac_profile::ReadState::unreadable || loaded.state==mac_profile::ReadState::future_schema;
        if(zone) {
            receipt=std::make_unique<mac_profile::DayReceipt>(*zone);
            if(auto saved=mac_profile::load_receipt(profile))receipt->restore(std::move(*saved),settings.draft,now);
        }
        mac_profile::clean_logs(profile,std::filesystem::file_time_type::clock::now());
    }
};
} // namespace

@interface DMLookupReply () {
@public
    std::unique_ptr<LookupResult> _value;
}
@end
@implementation DMLookupReply
- (uint64_t)token { return _value ? _value->selection : 0; }
- (NSDictionary<NSString *,id> *)metadata {
    if(!_value)return @{@"failure":@"schema",@"stages":@[],@"suggestions":@[]};
    NSMutableArray *stages=[NSMutableArray array], *suggestions=[NSMutableArray array];
    for(const auto& stage:_value->stages)[stages addObject:@{@"kind":resource_name(stage.resource),@"status":@(stage.status),@"bytes":@(stage.body_bytes),@"error":@(static_cast<int>(stage.error))}];
    for(const auto& choice:_value->suggestions)[suggestions addObject:@{@"id":text(choice.id),@"label":text(choice.label)}];
    return @{@"failure":failure_name(_value->failure),@"stages":stages,@"suggestions":suggestions,@"hasSchedule":@(_value->schedule.has_value())};
}
@end

@interface DMLookupOperation () { std::unique_ptr<OperationState> _state; }
@end
@implementation DMLookupOperation
- (instancetype)initWithStreet:(NSString *)street house:(NSString *)house token:(uint64_t)token suggestions:(BOOL)suggestions houseSuggestions:(BOOL)houseSuggestions {
    if((self=[super init])) {
        _state=std::make_unique<OperationState>(); _state->request.selection=token;
        try {
            _state->request.street=mac_json::utf8(street); _state->request.house=mac_json::utf8(house);
            _state->request.suggest_streets=suggestions; _state->request.suggest_houses=houseSuggestions; _state->valid=true;
        } catch(...) { _state->valid=false; }
    }
    return self;
}
- (void)cancel { if(_state)_state->cancellation.request_stop(); }
- (DMLookupReply *)performWithTransport:(DMGetTransport)transport {
    @autoreleasepool {
        auto result=std::make_unique<LookupResult>(); result->selection=_state->request.selection;
        result->failure=LookupFailure::schema;
        if(_state->valid && transport && !_state->started.exchange(true)) {
            *result=lookup_once(_state->request,[&](Request request,StopToken) {
                Completion value{request};
                @autoreleasepool {
                    try {
                        NSDictionary *input=@{@"kind":resource_name(request.resource.kind),@"query":text(request.resource.query_utf8),
                            @"streetID":text(request.resource.street_id),@"houseID":text(request.resource.house_id),
                            @"token":@(request.token),@"bodyLimit":@(request.limits.body_bytes),@"timeoutMS":@(request.limits.total_ms)};
                        NSDictionary *output=mac_json::object(transport(input));
                        value.request.token=token_number(output[@"token"]);
                        if([output[@"cleanupFailed"] isKindOfClass:NSNumber.class])value.cleanup_failed=[output[@"cleanupFailed"] boolValue];
                        value.error=error_code(mac_json::string(output[@"error"]));
                        value.status=static_cast<int>(mac_json::integer(output[@"status"],599,true));
                        value.content_type=mac_json::utf8(mac_json::string(output[@"mime"]));
                        id body=output[@"body"];
                        if(![body isKindOfClass:NSData.class] || [(NSData *)body length]>request.limits.body_bytes || value.content_type.size()>256)
                            throw std::invalid_argument("Invalid response bounds");
                        if(value.error==Error::none) {
                            if([(NSData *)body length])value.body.assign(static_cast<const char *>([(NSData *)body bytes]),[(NSData *)body length]);
                            id received=output[@"received"];
                            if(received && received!=NSNull.null) {
                                const double stamp=mac_json::number(received);
                                if(stamp < -11644473600.0 || stamp > 253402300799.0 || std::floor(stamp)!=stamp)
                                    throw std::invalid_argument("Invalid receipt time");
                                value.received_at=schedule::UtcInstant{static_cast<std::int64_t>(stamp)};
                            }
                        }
                    } catch(...) { value.error=Error::invalid_response; value.body.clear(); value.received_at.reset(); }
                }
                return value;
            },_state->cancellation.get_token());
        }
        DMLookupReply *reply=[[DMLookupReply alloc] init]; reply->_value=std::move(result); return reply;
    }
}
@end

@interface DMMonitorEngine () { std::unique_ptr<EngineState> _state; }
@end
@implementation DMMonitorEngine
- (instancetype)initWithProfile:(NSString *)profile epoch:(int64_t)epoch {
    if((self=[super init])) { try { _state=std::make_unique<EngineState>(profile,schedule::UtcInstant{epoch}); } catch(...) {} }
    return self;
}
+ (NSDictionary<NSString *,NSString *> *)normalizeStreet:(NSString *)street house:(NSString *)house {
    try {
        const auto draft=address_draft::normalize(mac_json::wide(street),mac_json::wide(house));
        if(!draft)return nil;
        return @{@"street":wide_text(draft->street),@"house":wide_text(draft->house)};
    } catch(...) { return nil; }
}
+ (NSString *)streetQuery:(NSString *)input {
    try {
        if(!address_draft::normalize(mac_json::wide(input),L"1"))return nil;
        return wide_text(mac_address_search::street(mac_json::utf8(input)).name);
    } catch(...) { return nil; }
}
- (BOOL)selectStreet:(NSString *)street house:(NSString *)house epoch:(int64_t)epoch {
    if(!_state)return NO;
    try {
        const auto draft=address_draft::normalize(mac_json::wide(street),mac_json::wide(house));
        if(!draft)return NO;
        if(_state->settings.draft!=*draft) {
            if(!mac_profile::remove_receipt(_state->profile)) { _state->storage_warning=true; return NO; }
            if(_state->receipt)_state->receipt->clear(schedule::UtcInstant{epoch});
        }
        _state->settings.draft=*draft;
        _state->storage_warning=!mac_profile::save_settings(_state->profile,_state->settings);
        return YES;
    } catch(...) { return NO; }
}
- (BOOL)recordEvent:(NSInteger)event status:(NSInteger)status reason:(NSInteger)reason epoch:(int64_t)epoch {
    if(!_state || event<0 || event>8 || status<0 || status>599 || reason<0 || reason>13)return NO;
    return mac_profile::append_event(_state->profile,static_cast<mac_profile::DiagnosticEvent>(event),schedule::UtcInstant{epoch},static_cast<int>(status),static_cast<int>(reason));
}
- (BOOL)setTheme:(NSString *)theme {
    if(!_state)return NO;
    try {
        const auto value=mac_json::utf8(theme);
        if(value!="system" && value!="light" && value!="dark")return NO;
        _state->settings.theme=value;
        _state->storage_warning=!mac_profile::save_settings(_state->profile,_state->settings);
        return !_state->storage_warning;
    } catch(...) { return NO; }
}
- (void)selectTomorrow:(BOOL)tomorrow { if(_state && _state->receipt)_state->receipt->select_tomorrow(tomorrow); }
- (BOOL)setFloatingVisible:(BOOL)visible positioned:(BOOL)positioned x:(NSInteger)x y:(NSInteger)y size:(NSInteger)size {
    if (!_state || size < 0 || size > 2 || x < -100000 || x > 100000 || y < -100000 || y > 100000) return NO;
    _state->settings.floating_visible=visible; _state->settings.floating_positioned=positioned;
    _state->settings.floating_x=static_cast<int>(x); _state->settings.floating_y=static_cast<int>(y);
    _state->settings.floating_size=static_cast<int>(size);
    _state->storage_warning=!mac_profile::save_settings(_state->profile,_state->settings);
    return !_state->storage_warning;
}
- (BOOL)acceptReply:(DMLookupReply *)reply epoch:(int64_t)epoch {
    if(!_state || !_state->receipt || !reply->_value)return NO;
    const auto& result=*reply->_value;
    if(result.failure!=LookupFailure::none || !result.schedule || !result.schedule->received_at)return NO;
    mac_profile::Receipt receipt{_state->settings.draft,result.resolution,result.schedule->body,*result.schedule->received_at};
    if(!_state->receipt->accept(receipt,_state->settings.draft,schedule::UtcInstant{epoch}))return NO;
    if(!mac_profile::save_receipt(_state->profile,receipt))_state->storage_warning=true;
    return YES;
}
- (NSDictionary<NSString *,id> *)snapshotAtEpoch:(int64_t)epoch {
    @autoreleasepool {
        if(!_state)return @{@"valid":@NO,@"theme":@"system",@"intervals":@[],@"tomorrowAvailable":@NO,@"forecast":@NO};
        const schedule::UtcInstant now{epoch};
        NSString *dayKey=@"";
        if(_state->zone)if(const auto day=_state->zone->local_date_at(now))
            dayKey=[NSString stringWithFormat:@"%04d-%02u-%02u",day->year,day->month,day->day];
        NSMutableArray *intervals=[NSMutableArray array];
        bool forecast=false,tomorrow=false,tomorrowAvailable=false,emergency=false,currentForecast=false,currentEmergency=false;
        NSString *countdown=@"",*currentCountdown=@"",*address=@"Адресу не задано";
        id received=NSNull.null;
        unsigned total=0;
        if(!_state->settings.draft.street.empty())address=[NSString stringWithFormat:@"%@, %@",wide_text(_state->settings.draft.street),wide_text(_state->settings.draft.house)];
        if(_state->receipt) {
            const auto& window=_state->receipt->view(now);
            tomorrow=window.viewing_tomorrow(); tomorrowAvailable=window.has_tomorrow();
            if(const auto& today=window.today()) {
                currentEmergency=today->state==popup_schedule::State::emergency;
                currentForecast=today->state==popup_schedule::State::published && today->verified;
            }
            if(const auto day=window.selected()) {
                emergency=day->state==popup_schedule::State::emergency;
                forecast=day->state==popup_schedule::State::published && day->verified;
                if(forecast) {
                    unsigned cursor=0;
                    for(const auto& span:day->outages) {
                        if(cursor<span.start_minute)[intervals addObject:@{@"start":@(cursor),@"end":@(span.start_minute),@"power":@YES}];
                        [intervals addObject:@{@"start":@(span.start_minute),@"end":@(span.end_minute),@"power":@NO}];
                        cursor=span.end_minute;
                    }
                    if(cursor<1440)[intervals addObject:@{@"start":@(cursor),@"end":@1440,@"power":@YES}];
                    total=popup_schedule::total_outage_minutes(day);
                }
            }
            if(const auto estimate=_state->receipt->estimate(now))currentCountdown=text(estimate->ukrainian_text);
            if(!tomorrow)countdown=currentCountdown;
            if(const auto& saved=_state->receipt->saved(now)) {
                received=@(saved->received.epoch_seconds);
                address=[NSString stringWithFormat:@"%@, %@",text(saved->resolution.address.displayed_street),text(saved->resolution.address.displayed_house)];
            }
        }
        return @{@"valid":@YES,@"street":wide_text(_state->settings.draft.street),@"house":wide_text(_state->settings.draft.house),
            @"address":address,@"theme":text(_state->settings.theme),@"storageWarning":@(_state->storage_warning),
            @"kyivDay":dayKey,@"forecast":@(forecast),@"emergency":@(emergency),@"tomorrow":@(tomorrow),
            @"currentForecast":@(currentForecast),@"currentEmergency":@(currentEmergency),@"currentCountdown":currentCountdown,
            @"tomorrowAvailable":@(tomorrowAvailable),@"countdown":countdown,@"intervals":intervals,
            @"totalOutageMinutes":@(total),@"received":received,
            @"floatingVisible":@(_state->settings.floating_visible), @"floatingPositioned":@(_state->settings.floating_positioned),
            @"floatingX":@(_state->settings.floating_x), @"floatingY":@(_state->settings.floating_y), @"floatingSize":@(_state->settings.floating_size)};
    }
}
@end
