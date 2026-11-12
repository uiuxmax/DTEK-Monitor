#pragma once
#include "../../yasno_lookup_types.h"
#include <atomic>
#include <functional>
#include <memory>
#include <utility>

namespace yasno::lookup {
// Only cancellation state is needed by this synchronous worker. The owner also
// cancels its native attempt. No experimental libc++ or system state is required.
class StopToken {
    std::shared_ptr<std::atomic<bool>> value_;
    friend class StopSource;
    explicit StopToken(std::shared_ptr<std::atomic<bool>> value) : value_(std::move(value)) {}
public:
    StopToken() = default;
    bool stop_requested() const { return value_ && value_->load(std::memory_order_acquire); }
};
class StopSource {
    std::shared_ptr<std::atomic<bool>> value_ = std::make_shared<std::atomic<bool>>(false);
public:
    StopToken get_token() const { return StopToken{value_}; }
    bool stop_requested() const { return value_ && value_->load(std::memory_order_acquire); }
    bool request_stop() { return value_ && !value_->exchange(true,std::memory_order_acq_rel); }
};
using Get = std::function<https::Completion(https::Request, StopToken)>;
LookupResult lookup_once(LookupRequest request, Get get, StopToken stop = {});
} // namespace yasno::lookup
