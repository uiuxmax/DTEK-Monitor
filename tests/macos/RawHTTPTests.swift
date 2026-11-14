import Foundation

private struct WireCase {
    let name: String
    let wire: Data
    let error: String?
    let cap: Int
    init(_ name: String, _ wire: String, _ error: String? = nil, cap: Int = 2_000_000) {
        self.name = name; self.wire = Data(wire.utf8); self.error = error; self.cap = cap
    }
}

func runRawHTTPTests() throws {
    let prefix = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
    let fixed = prefix + "Content-Length: 2\r\n\r\n{}"
    let chunk = prefix + "Transfer-Encoding: chunked\r\n\r\n"
    let cases: [WireCase] = [
        .init("fixed", fixed),
        .init("close delimited", prefix + "\r\n{}"),
        .init("chunked", chunk + "2\r\n{}\r\n0\r\n\r\n"),
        .init("split chunks", chunk + "1\r\n{\r\n1\r\n}\r\n0\r\n\r\n"),
        .init("case insensitive fields", "HTTP/1.1 200 OK\r\nCONTENT-TYPE: Application/Json\r\nCONTENT-ENCODING: IDENTITY\r\nContent-Length: 2\r\n\r\n{}"),
        .init("parameters", fixed.replacingOccurrences(of: "application/json", with: " application/json; charset=utf-8\t")),
        .init("HTTP1.0", fixed.replacingOccurrences(of: "HTTP/1.1", with: "HTTP/1.0")),
        .init("empty reason", fixed.replacingOccurrences(of: "200 OK", with: "200")),
        .init("declared cap boundary", fixed, cap: 2),
        .init("unknown cap boundary", prefix + "\r\n{}", cap: 2),
        .init("chunk cap boundary", chunk + "2\r\n{}\r\n0\r\n\r\n", cap: 2),
        .init("duplicate type", prefix + "Content-Type: application/json\r\n\r\n{}", "invalid_response"),
        .init("duplicate length", prefix + "Content-Length: 2\r\ncontent-length: 2\r\n\r\n{}", "invalid_response"),
        .init("conflicting lengths", prefix + "Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}", "invalid_response"),
        .init("duplicate encoding", prefix + "Content-Encoding: identity\r\nContent-Encoding: identity\r\n\r\n{}", "invalid_response"),
        .init("duplicate transfer", prefix + "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n", "invalid_response"),
        .init("duplicate unrelated field", prefix + "X-Test: first\r\nx-test: second\r\n\r\n{}", "invalid_response"),
        .init("repeatable cookies ignored", prefix + "Set-Cookie: a=b\r\nSet-Cookie: c=d\r\n\r\n{}"),
        .init("single cookie ignored", prefix + "Set-Cookie: a=b\r\nContent-Length: 2\r\n\r\n{}"),
        .init("CDN cookies with chunked JSON", chunk + "Set-Cookie: a=b; Secure; HttpOnly\r\nset-cookie: c=d; Path=/\r\nSET-COOKIE: e=f; Expires=Wed, 18 Nov 2026 00:00:00 GMT\r\n\r\n2\r\n{}\r\n0\r\n\r\n"),
        .init("cookies cannot hide duplicate type", prefix + "Set-Cookie: a=b\r\nContent-Type: application/json\r\nSet-Cookie: c=d\r\n\r\n{}", "invalid_response"),
        .init("cookies cannot hide duplicate length", prefix + "Set-Cookie: a=b\r\nContent-Length: 2\r\nset-cookie: c=d\r\ncontent-length: 2\r\n\r\n{}", "invalid_response"),
        .init("cookies cannot hide conflicting framing", chunk + "Set-Cookie: a=b\r\nContent-Length: 2\r\n\r\n{}", "invalid_response"),
        .init("cookies cannot hide duplicate metadata", prefix + "Set-Cookie: a=b\r\nX-Test: first\r\nset-cookie: c=d\r\nx-test: second\r\n\r\n{}", "invalid_response"),
        .init("cookie control rejected", prefix + "Set-Cookie: a=\u{1}b\r\n\r\n{}", "invalid_response"),
        .init("cookie folding rejected", prefix + "Set-Cookie: a=b\r\n c=d\r\n\r\n{}", "invalid_response"),
        .init("cookie field syntax rejected", prefix + "Set-Cookie : a=b\r\n\r\n{}", "invalid_response"),
        .init("cookies cannot hide forbidden status", "HTTP/1.1 403 Forbidden\r\nSet-Cookie: a=b\r\nSet-Cookie: c=d\r\n\r\n{}", "http"),
        .init("cookies cannot hide rate limit", "HTTP/1.1 429 Too Many Requests\r\nSet-Cookie: a=b\r\nSet-Cookie: c=d\r\n\r\n{}", "http"),
        .init("NUL", prefix + "X: a\0b\r\n\r\n{}", "invalid_response"),
        .init("DEL", prefix + "X: a\u{7f}b\r\n\r\n{}", "invalid_response"),
        .init("control", prefix + "X: a\u{1}b\r\n\r\n{}", "invalid_response"),
        .init("bare LF", prefix + "X: a\nb\r\n\r\n{}", "invalid_response"),
        .init("bare CR", prefix + "X: a\rb\r\n\r\n{}", "invalid_response"),
        .init("folded header", prefix + "X: a\r\n b\r\n\r\n{}", "invalid_response"),
        .init("space before colon", prefix + "X : a\r\n\r\n{}", "invalid_response"),
        .init("invalid field name", prefix + "X(1): a\r\n\r\n{}", "invalid_response"),
        .init("missing colon", prefix + "X\r\n\r\n{}", "invalid_response"),
        .init("empty field name", prefix + ": x\r\n\r\n{}", "invalid_response"),
        .init("wrong protocol", fixed.replacingOccurrences(of: "HTTP/1.1", with: "HTTP/2"), "invalid_response"),
        .init("wrong status syntax", fixed.replacingOccurrences(of: "200 OK", with: "2000 OK"), "invalid_response"),
        .init("status below range", fixed.replacingOccurrences(of: "200 OK", with: "099 OK"), "invalid_response"),
        .init("status above range", fixed.replacingOccurrences(of: "200 OK", with: "600 OK"), "invalid_response"),
        .init("signed status", fixed.replacingOccurrences(of: "200 OK", with: "+20 OK"), "invalid_response"),
        .init("redirect", fixed.replacingOccurrences(of: "200 OK", with: "302 Found"), "http"),
        .init("forbidden", fixed.replacingOccurrences(of: "200 OK", with: "403 Forbidden"), "http"),
        .init("rate limit", fixed.replacingOccurrences(of: "200 OK", with: "429 Too Many Requests"), "http"),
        .init("partial response", fixed.replacingOccurrences(of: "200 OK", with: "206 Partial Content"), "http"),
        .init("interim status not final", fixed.replacingOccurrences(of: "200 OK", with: "100 Continue"), "http"),
        .init("empty stream", "", "incomplete_body"),
        .init("truncated headers", prefix, "incomplete_body"),
        .init("empty fixed body", prefix + "Content-Length: 0\r\n\r\n", "incomplete_body"),
        .init("truncated fixed body", prefix + "Content-Length: 3\r\n\r\n{}", "incomplete_body"),
        .init("body after zero length", prefix + "Content-Length: 0\r\n\r\n{}", "invalid_response"),
        .init("declared overflow", prefix + "Content-Length: 3\r\n\r\n{}", "body_too_large", cap: 2),
        .init("stream overflow", prefix + "\r\n{}x", "body_too_large", cap: 2),
        .init("chunk overflow", chunk + "3\r\n{}x\r\n0\r\n\r\n", "body_too_large", cap: 2),
        .init("length integer overflow", prefix + "Content-Length: 999999999999999999999999\r\n\r\n{}", "invalid_response"),
        .init("negative length", prefix + "Content-Length: -2\r\n\r\n{}", "invalid_response"),
        .init("positive signed length", prefix + "Content-Length: +2\r\n\r\n{}", "invalid_response"),
        .init("joined length", prefix + "Content-Length: 2, 2\r\n\r\n{}", "invalid_response"),
        .init("length and transfer conflict", prefix + "Content-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}", "invalid_response"),
        .init("missing MIME", "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", "invalid_response"),
        .init("wrong MIME", fixed.replacingOccurrences(of: "application/json", with: "text/html"), "invalid_response"),
        .init("long MIME", fixed.replacingOccurrences(of: "application/json", with: "application/json;"+String(repeating: "x", count: 250)), "invalid_response"),
        .init("gzip", prefix + "Content-Encoding: gzip\r\n\r\n{}", "invalid_response"),
        .init("unsupported transfer", prefix + "Transfer-Encoding: identity\r\n\r\n{}", "invalid_response"),
        .init("joined transfer", prefix + "Transfer-Encoding: gzip, chunked\r\n\r\n{}", "invalid_response"),
        .init("invalid hex", chunk + "g\r\n{}\r\n0\r\n\r\n", "invalid_response"),
        .init("signed hex", chunk + "+2\r\n{}\r\n0\r\n\r\n", "invalid_response"),
        .init("hex whitespace", chunk + " 2\r\n{}\r\n0\r\n\r\n", "invalid_response"),
        .init("hex overflow", chunk + "ffffffffffffffff\r\n", "invalid_response"),
        .init("chunk line cap", chunk + String(repeating: "0", count: 33), "invalid_response"),
        .init("chunk extension unsupported", chunk + "2;x=y\r\n{}\r\n0\r\n\r\n", "invalid_response"),
        .init("missing chunk CRLF", chunk + "2\r\n{}X\r\n0\r\n\r\n", "invalid_response"),
        .init("truncated chunk", chunk + "2\r\n{", "incomplete_body"),
        .init("missing zero chunk", chunk + "2\r\n{}\r\n", "incomplete_body"),
        .init("truncated final CRLF", chunk + "2\r\n{}\r\n0\r\n\r", "incomplete_body"),
        .init("trailers unsupported", chunk + "2\r\n{}\r\n0\r\nX: y\r\n\r\n", "invalid_response"),
        .init("extra bytes after length", fixed + "x", "invalid_response"),
        .init("extra bytes after chunks", chunk + "2\r\n{}\r\n0\r\n\r\nx", "invalid_response")
    ]
    var count = 0
    func demand(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "RawHTTPTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    for item in cases {
        for segment in [1, 7, 4096] {
            let parser = RawHTTPResponse(bodyCap: item.cap)
            var offset = 0
            while offset < item.wire.count && parser.error == nil {
                let size = min(segment, parser.nextReadLimit, item.wire.count-offset)
                try demand((1...4096).contains(size), item.name+": receive bound")
                parser.feed(item.wire.subdata(in: offset..<offset+size)); offset += size
            }
            let valid = parser.eof()
            try demand(parser.error == item.error, item.name+": unexpected error \(parser.error ?? "none")")
            try demand(valid == (item.error == nil), item.name+": EOF validity")
            try demand(parser.body == (valid ? Data("{}".utf8) : Data()), item.name+": body")
            try demand(parser.headers["set-cookie"] == nil, item.name+": cookies never retained")
            try demand(parser.rawHeaderBytes <= RawHTTPResponse.headerCap, item.name+": header bound")
            count += 1
        }
    }
    for field in ["X-Fill", "Set-Cookie"] {
        let base = prefix + "Content-Length: 2\r\n" + field + ": "
        for extra in [0, 1] {
            let wire = Data((base + String(repeating: "h", count: RawHTTPResponse.headerCap-base.utf8.count-4+extra) + "\r\n\r\n{}").utf8)
            let parser = RawHTTPResponse()
            var offset = 0
            while offset < wire.count && parser.error == nil {
                let size = min(parser.nextReadLimit, wire.count-offset)
                parser.feed(wire.subdata(in: offset..<offset+size)); offset += size
            }
            try demand(parser.eof() == (extra == 0), "exact header cap")
            try demand(parser.rawHeaderBytes == RawHTTPResponse.headerCap, "header append cap")
            if extra == 1 { try demand(parser.diagnostic == "header_cap", "over-cap rejection before parse") }
            count += 1
        }
    }
    let oversized = RawHTTPResponse()
    oversized.feed(Data(repeating: 65, count: 4097))
    try demand(oversized.error == "invalid_response" && oversized.rawHeaderBytes == 0, "oversized input before copy")
    count += 1
    print("RESULT \(count)/\(count) raw HTTP parser checks passed; \(cases.count) vectors with 3 segment sizes")
}
