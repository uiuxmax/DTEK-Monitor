#pragma once

#include "yasno_schedule_adapter.h"
#include "https_resource.h"
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>

// Local contract for a future Windows HTTPS driver. No sockets or Windows
// network handles exist here. One Exchange represents exactly one GET attempt.
namespace yasno::https {
inline constexpr char host[] = "app.yasno.ua";
inline constexpr char schedule_path[] = "/api/blackout-service/public/shutdowns/regions/25/dsos/902/planned-outages";
inline constexpr unsigned port = 443;

struct Limits {
    std::size_t body_bytes = 2'000'000;
    std::int64_t total_ms = 30'000;
};
struct Request {
    std::uint64_t token;
    AddressResolution resolution;
    Limits limits{};
    Resource resource{};
};
enum class Error {
    none, invalid_request, dns, tls, connection, http, timeout, cancelled,
    invalid_response, body_too_large, incomplete_body, cleanup
};
struct Headers {
    int status = 0;
    std::string content_type;
    std::optional<std::size_t> content_length;
    std::string content_encoding;
    bool tls_verified = false;
};

// Owns bytes and request context, so asynchronous UI changes and read buffers
// cannot relabel a reply. Pass response() immediately to Flow::receive using
// request.token and *received_at. Response's string_views borrow this object.
struct Completion {
    Request request;
    Error error = Error::none;
    int status = 0;
    std::string content_type;
    std::string body;
    std::optional<schedule::UtcInstant> received_at;
    // Native handle cleanup was not confirmed. A failed attempt keeps its primary
    // error; an otherwise successful attempt becomes Error::cleanup with no body.
    bool cleanup_failed = false;
    // Fixed diagnostic code for a failed native request; never contains provider data.
    std::string diagnostic;

    Response response() const & {
        using schedule::Failure;
        Failure failure = Failure::none;
        switch (error) {
        case Error::none: break;
        case Error::dns: failure = Failure::dns; break;
        case Error::tls: failure = Failure::tls; break;
        case Error::timeout: failure = Failure::timeout; break;
        case Error::invalid_response:
        case Error::body_too_large:
        case Error::incomplete_body: failure = Failure::unexpected_body; break;
        default: failure = Failure::http; break;
        }
        return {failure, status, content_type, body};
    }
    Response response() const && = delete;
};

class Exchange {
    Completion result_;
    bool terminal_ = false;
    bool headers_ = false;
    std::optional<std::size_t> length_;
    std::int64_t elapsed_ = 0;

    void fail(Error error) {
        terminal_ = true;
        result_.error = error;
        result_.body.clear();
        result_.received_at.reset();
    }
    bool active(std::int64_t elapsed_ms) {
        if (terminal_) return false;
        if (elapsed_ms < elapsed_) { fail(Error::invalid_response); return false; }
        elapsed_ = elapsed_ms;
        if (elapsed_ms >= result_.request.limits.total_ms) { fail(Error::timeout); return false; }
        return true;
    }
    static bool json_type(std::string_view type) {
        type = type.substr(0, type.find(';'));
        while (!type.empty() && (type.front() == ' ' || type.front() == '\t')) type.remove_prefix(1);
        while (!type.empty() && (type.back() == ' ' || type.back() == '\t')) type.remove_suffix(1);
        std::string value{type};
        for (auto& ch : value) if (ch >= 'A' && ch <= 'Z') ch += 'a' - 'A';
        return value == "application/json";
    }
public:
    explicit Exchange(Request request) : result_{std::move(request), Error::none, 0, {}, {}, {}} {
        const auto& limits = result_.request.limits;
        if (!result_.request.token || !limits.body_bytes || limits.body_bytes > 2'000'000 ||
            limits.total_ms <= 0 || limits.total_ms > 30'000) fail(Error::invalid_request);
    }
    Exchange(const Exchange&) = delete;
    Exchange& operator=(const Exchange&) = delete;
    Exchange(Exchange&&) = delete;
    Exchange& operator=(Exchange&&) = delete;
    const Request& request() const { return result_.request; }
    bool done() const { return terminal_; }
    // elapsed_ms is monotonic milliseconds since this attempt began, including
    // DNS/connect/TLS/read time. Driver must enforce the deadline while blocked.
    void tick(std::int64_t elapsed_ms) { active(elapsed_ms); }
    void cancel() { if (!terminal_) fail(Error::cancelled); }
    void failed(Error error, std::int64_t elapsed_ms, std::string diagnostic = {}) {
        if (active(elapsed_ms)) {
            fail(error == Error::none ? Error::invalid_response : error);
            result_.diagnostic = std::move(diagnostic);
        }
    }
    void headers(const Headers& value, std::int64_t elapsed_ms) {
        if (!active(elapsed_ms)) return;
        if (headers_) { fail(Error::invalid_response); return; }
        if (!value.tls_verified) { fail(Error::tls); return; }
        result_.status = value.status;
        // No redirect, conditional request or partial-response semantics.
        if (value.status != 200) { fail(Error::http); return; }
        if (value.content_type.size() > 256 || !json_type(value.content_type) ||
            (!value.content_encoding.empty() && value.content_encoding != "identity")) {
            fail(Error::invalid_response); return;
        }
        if (value.content_length && *value.content_length > result_.request.limits.body_bytes) {
            fail(Error::body_too_large); return;
        }
        result_.content_type = value.content_type;
        length_ = value.content_length;
        headers_ = true;
    }
    void append(std::string_view bytes, std::int64_t elapsed_ms) {
        if (!active(elapsed_ms)) return;
        if (!headers_) { fail(Error::invalid_response); return; }
        if (bytes.size() > result_.request.limits.body_bytes - result_.body.size()) {
            fail(Error::body_too_large); return;
        }
        if (length_ && bytes.size() > *length_ - result_.body.size()) {
            fail(Error::invalid_response); return;
        }
        result_.body.append(bytes);
    }
    void finish(schedule::UtcInstant received_at, std::int64_t elapsed_ms) {
        if (!active(elapsed_ms)) return;
        if (!headers_ || result_.body.empty() || (length_ && result_.body.size() != *length_)) {
            fail(Error::incomplete_body); return;
        }
        terminal_ = true;
        result_.received_at = received_at;
    }
    // No partial body may escape while an attempt is pending. Taking completion
    // is a consuming operation, allowing the driver to deliver it at most once.
    std::optional<Completion> take() {
        if (!terminal_ || delivered_) return std::nullopt;
        delivered_ = true;
        return std::move(result_);
    }
private:
    bool delivered_ = false;
};
} // namespace yasno::https
