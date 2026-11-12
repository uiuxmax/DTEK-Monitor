import Foundation

// Narrow HTTP/1 response parser for a single fixed GET. No repair, decompression,
// redirects or retry policy. Own buffers are bounded before appending bytes.
final class RawHTTPResponse {
    static let headerCap = 65_536
    private enum Phase { case headers, fixed, closeDelimited, size, chunk, chunkCR, finalCR, complete }
    private var phase = Phase.headers
    private var head = [UInt8]()
    private var line = [UInt8]()
    private var remaining = 0
    private var crPosition = 0
    private let bodyCap: Int
    private(set) var body = Data()
    private(set) var headers: [String: String] = [:]
    private(set) var status = 0
    private(set) var error: String?
    private(set) var diagnostic = ""
    private(set) var rawHeaderBytes = 0

    init(bodyCap: Int = 2_000_000) {
        self.bodyCap = bodyCap
        head.reserveCapacity(Self.headerCap) // Fixed engineering cap, never a declared length.
        line.reserveCapacity(32)
    }
    var nextReadLimit: Int {
        if phase == .headers { return max(1, min(4096, Self.headerCap - head.count)) }
        if phase == .complete { return 1 } // Require EOF; detect bytes after a framed message.
        return max(1, min(4096, bodyCap - body.count + 1))
    }
    private func fail(_ value: String = "invalid_response", _ code: String) {
        guard error == nil else { return }
        error = value; diagnostic = code; body.removeAll()
    }
    private func append(_ bytes: ArraySlice<UInt8>) {
        guard bytes.count <= bodyCap - body.count else { fail("body_too_large", "body_cap"); return }
        body.append(contentsOf: bytes)
    }
    private func parseHeaders() {
        // Latin-1 preserves header bytes; Unicode normalization is never used.
        guard let text = String(bytes: head.dropLast(4), encoding: .isoLatin1) else { fail("invalid_response", "header_encoding"); return }
        let fields = text.components(separatedBy: "\r\n")
        guard let first = fields.first, first.utf8.count >= 12 else { fail("invalid_response", "status"); return }
        let statusParts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(String(statusParts[0])),
              statusParts[1].utf8.count == 3, statusParts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(statusParts[1]), (100...599).contains(number) else {
            fail("invalid_response", "status"); return
        }
        status = number
        let tokens = Set("!#$%&'*+-.^_`|~".utf8)
        for field in fields.dropFirst() {
            guard let colon = field.firstIndex(of: ":"), colon != field.startIndex else { fail("invalid_response", "field"); return }
            let namePart = field[..<colon]
            guard namePart.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || tokens.contains($0) }) else { fail("invalid_response", "field_name"); return }
            let name = namePart.lowercased()
            guard headers[name] == nil else { fail("invalid_response", "duplicate_field"); return }
            let value = field[field.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers[name] = value
        }
        // HTTP error status is preserved for the session-wide 403/429 gate.
        guard status == 200 else { fail("http", "http_status"); return }
        let mime = headers["content-type"] ?? ""
        let encoding = headers["content-encoding"] ?? ""
        guard mime.utf8.count <= 256,
              mime.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
              encoding.isEmpty || encoding.lowercased() == "identity" else { fail("invalid_response", "representation"); return }
        let transfer = headers["transfer-encoding"]
        if let length = headers["content-length"] {
            guard transfer == nil, !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
                  let count = Int(length) else { fail("invalid_response", "framing"); return }
            guard count <= bodyCap else { fail("body_too_large", "declared_body_cap"); return }
            remaining = count
            phase = count == 0 ? .complete : .fixed
        } else if let transfer = transfer {
            guard transfer.lowercased() == "chunked" else { fail("invalid_response", "transfer_coding"); return }
            phase = .size
        } else { phase = .closeDelimited }
    }
    func feed(_ data: Data) {
        guard error == nil else { return }
        guard data.count <= 4096 else { fail("invalid_response", "receive_cap"); return }
        let bytes = [UInt8](data) // The caller caps every native receive at 4096 bytes.
        var i = 0
        while i < bytes.count && error == nil {
            switch phase {
            case .headers:
                let byte = bytes[i]; i += 1
                guard head.count < Self.headerCap else { fail("invalid_response", "header_cap"); return }
                if byte == 0 || byte == 127 || (byte < 32 && ![9, 10, 13].contains(byte)) ||
                    (byte == 10 && head.last != 13) || (head.last == 13 && byte != 10) {
                    fail("invalid_response", "header_control"); return
                }
                head.append(byte); rawHeaderBytes = head.count
                if head.suffix(4).elementsEqual([13, 10, 13, 10]) { parseHeaders() }
                else if head.count == Self.headerCap { fail("invalid_response", "header_cap") }
            case .fixed:
                let count = min(remaining, bytes.count - i)
                append(bytes[i..<i+count]); i += count; remaining -= count
                if remaining == 0 { phase = .complete }
            case .closeDelimited:
                append(bytes[i...]); i = bytes.count
            case .size:
                let byte = bytes[i]; i += 1
                guard line.count < 32 else { fail("invalid_response", "chunk_line_cap"); return }
                line.append(byte)
                if line.suffix(2).elementsEqual([13, 10]) {
                    let digits = line.dropLast(2)
                    guard !digits.isEmpty, digits.count <= 16,
                          digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                          let count = Int(String(bytes: digits, encoding: .ascii)!, radix: 16) else {
                        fail("invalid_response", "chunk_size"); return
                    }
                    guard count <= bodyCap - body.count else { fail("body_too_large", "chunk_body_cap"); return }
                    line.removeAll(keepingCapacity: true); remaining = count
                    phase = count == 0 ? .finalCR : .chunk; crPosition = 0
                }
            case .chunk:
                let count = min(remaining, bytes.count - i)
                append(bytes[i..<i+count]); i += count; remaining -= count
                if remaining == 0 { phase = .chunkCR; crPosition = 0 }
            case .chunkCR, .finalCR:
                let expected: UInt8 = crPosition == 0 ? 13 : 10
                guard bytes[i] == expected else { fail("invalid_response", "chunk_terminator"); return }
                i += 1; crPosition += 1
                if crPosition == 2 { phase = phase == .finalCR ? .complete : .size; crPosition = 0 }
            case .complete: fail("invalid_response", "trailing_bytes")
            }
        }
    }
    func eof() -> Bool {
        guard error == nil else { return false }
        guard (phase == .complete || phase == .closeDelimited), !body.isEmpty else {
            fail("incomplete_body", "framed_eof"); return false
        }
        return true
    }
}
