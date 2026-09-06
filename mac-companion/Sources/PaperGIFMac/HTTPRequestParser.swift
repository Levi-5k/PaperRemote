import Foundation

enum HTTPRequestParseResult: Equatable {
    case incomplete
    case complete(Data)
    case invalid
}

enum HTTPRequestParser {
    static let maximumRequestBytes = 64 * 1024
    private static let headerSeparator = Data("\r\n\r\n".utf8)

    static func parse(_ data: Data) -> HTTPRequestParseResult {
        guard data.count <= maximumRequestBytes else { return .invalid }
        guard let headerEnd = data.range(of: headerSeparator) else {
            return data.count == maximumRequestBytes ? .invalid : .incomplete
        }
        guard let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }

        var contentLength: Int?
        for line in header.split(separator: "\r\n", omittingEmptySubsequences: false).dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return .invalid }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame {
                return .invalid
            }
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                guard !value.isEmpty,
                      value.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let parsedLength = Int(value),
                      parsedLength <= maximumRequestBytes - headerEnd.upperBound else {
                    return .invalid
                }
                if let contentLength, contentLength != parsedLength {
                    return .invalid
                }
                contentLength = parsedLength
            }
        }

        let totalLength = headerEnd.upperBound + (contentLength ?? 0)
        guard data.count >= totalLength else { return .incomplete }
        return .complete(Data(data.prefix(totalLength)))
    }

    static func hasBearerToken(_ expectedToken: String, in request: Data) -> Bool {
        guard let headerEnd = request.range(of: headerSeparator),
              let header = String(data: request[..<headerEnd.lowerBound], encoding: .utf8) else {
            return false
        }
        for line in header.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Authorization") == .orderedSame else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            let credentials = value.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard credentials.count == 2,
                  credentials[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
                return false
            }
            return String(credentials[1]) == expectedToken
        }
        return false
    }
}
