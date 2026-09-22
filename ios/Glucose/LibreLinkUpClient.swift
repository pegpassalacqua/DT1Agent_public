import Foundation
import CryptoKit

/// Direct on-device client for the unofficial LibreLinkUp API — the
/// follower API the LibreLinkUp app itself uses. No server involved.
///
/// Endpoints, headers and the region-redirect handshake follow
/// pylibrelinkup (github.com/robberwick/pylibrelinkup), used as the
/// protocol reference.
actor LibreLinkUpClient {
    struct RawReading {
        let valueMgDl: Double
        /// nil when LibreLinkUp did not report one. Only the "current"
        /// measurement (connection.glucoseMeasurement) carries TrendArrow —
        /// the graphData history array has no such field at all, so a
        /// history point genuinely has NO known trend. Defaulting it to
        /// .stable would claim "flat" for readings that may have been
        /// rising or falling fast.
        let trend: Int?
        let isHigh: Bool
        let isLow: Bool
        let timestamp: Date // factory_timestamp (UTC)
    }

    enum LLUError: LocalizedError {
        case invalidCredentials
        case noPatients
        case badResponse(Int, String)
        case notAuthenticated
        case actionRequiredInApp
        case unknownRegion(String)

        var errorDescription: String? {
            switch self {
            case .invalidCredentials: String(localized: "Invalid LibreLinkUp email or password.")
            case .noPatients: String(localized: "No connections on this account — accept the sharing invitation in the LibreLinkUp app (see the README).")
            case .actionRequiredInApp: String(localized: "LibreLinkUp needs an action in the official app: open the LibreLinkUp app with this account and accept the terms / privacy policy or confirm your email.")
            case .unknownRegion(let region): String(localized: "Unknown LibreLinkUp region: \(region).")
            case .badResponse(let code, _):
                switch code {
                case 401, 403: String(localized: "LibreLinkUp rejected the session — check your email and password in Settings.")
                case 429: String(localized: "LibreLinkUp is rate-limiting requests — try again in a few minutes.")
                case 500...599: String(localized: "LibreLinkUp is unavailable (error \(code)).")
                default: String(localized: "LibreLinkUp responded with error \(code).")
                }
            case .notAuthenticated: String(localized: "LibreLinkUp session not authenticated.")
            }
        }
    }

    /// Every login starts at the EU host; accounts elsewhere get a redirect
    /// telling us their region. The resolved host is remembered so later
    /// logins skip the extra round trip.
    private static let regionKey = "lluRegionHost"
    private var base = URL(string: UserDefaults.standard.string(forKey: regionKey) ?? "https://api-eu.libreview.io")!

    /// Region codes as returned in the login redirect (see pylibrelinkup's
    /// APIUrl). US and RU use hosts without the "api-<region>" pattern.
    private static func host(forRegion region: String) -> URL? {
        switch region.lowercased() {
        case "us": URL(string: "https://api.libreview.io")
        case "ru": URL(string: "https://api.libreview.ru")
        case "eu", "eu2", "ae", "ap", "au", "ca", "de", "fr", "jp", "la":
            URL(string: "https://api-\(region.lowercased()).libreview.io")
        default: nil
        }
    }

    private var token: String?
    private var accountIdHash: String?
    private var patientId: String?

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy hh:mm:ss a"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func baseHeaders() -> [String: String] {
        var h = [
            "accept-encoding": "gzip",
            "cache-control": "no-cache",
            "connection": "Keep-Alive",
            "content-type": "application/json",
            "product": "llu.android",
            "version": "4.16.0",
        ]
        if let token { h["authorization"] = "Bearer \(token)" }
        if let accountIdHash { h["account-id"] = accountIdHash }
        return h
    }

    private func call(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        for (k, v) in baseHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // Only an auth rejection means the session itself is dead —
            // forget it so the next call logs in again. Rate limiting (429)
            // or a LibreLinkUp outage (5xx) must NOT trigger a fresh login:
            // hammering the login endpoint is what gets accounts locked.
            if code == 401 || code == 403 { signOut() }
            throw LLUError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLUError.badResponse(code, "response is not JSON")
        }
        return obj
    }

    /// Logs in and picks the first connected patient (the account being
    /// followed). Follows at most one region redirect.
    func authenticate(email: String, password: String) async throws {
        try await authenticate(email: email, password: password, allowRedirect: true)
    }

    private func authenticate(email: String, password: String, allowRedirect: Bool) async throws {
        let obj = try await call("llu/auth/login", method: "POST", body: ["email": email, "password": password])
        let status = obj["status"] as? Int

        // Too many attempts: LibreLinkUp answers inside the body, often with
        // HTTP 200. Must not be reported as a wrong password.
        if status == 429 { throw LLUError.badResponse(429, "") }

        if let data = obj["data"] as? [String: Any] {
            if data["redirect"] as? Bool == true, let region = data["region"] as? String {
                guard allowRedirect, let host = Self.host(forRegion: region) else {
                    throw LLUError.unknownRegion(region)
                }
                base = host
                UserDefaults.standard.set(host.absoluteString, forKey: Self.regionKey)
                return try await authenticate(email: email, password: password, allowRedirect: false)
            }
            // Terms of use / privacy policy / email verification pending.
            if let step = data["step"] as? [String: Any], step["type"] != nil {
                throw LLUError.actionRequiredInApp
            }
        }

        guard status == 0,
              let data = obj["data"] as? [String: Any],
              let authTicket = data["authTicket"] as? [String: Any],
              let newToken = authTicket["token"] as? String,
              let user = data["user"] as? [String: Any],
              let userId = user["id"] as? String
        else {
            throw LLUError.invalidCredentials
        }

        token = newToken
        accountIdHash = SHA256.hash(data: Data(userId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        try await resolvePatient()
    }

    private func resolvePatient() async throws {
        var req = URLRequest(url: base.appendingPathComponent("llu/connections"))
        for (k, v) in baseHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw LLUError.badResponse(code, "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let connections = obj["data"] as? [[String: Any]],
              let first = connections.first,
              let pid = first["patientId"] as? String
        else {
            throw LLUError.noPatients
        }
        patientId = pid
    }

    /// Current reading + the LibreLinkUp-side rolling ~12h history.
    func graph() async throws -> (current: RawReading?, history: [RawReading]) {
        guard token != nil else { throw LLUError.notAuthenticated }
        guard let patientId else { throw LLUError.noPatients }

        let obj = try await call("llu/connections/\(patientId)/graph")
        guard let data = obj["data"] as? [String: Any] else {
            throw LLUError.badResponse(0, "missing data field")
        }

        let current: RawReading? = (data["connection"] as? [String: Any])
            .flatMap { $0["glucoseMeasurement"] as? [String: Any] }
            .flatMap(parseReading)

        let historyRaw = data["graphData"] as? [[String: Any]] ?? []
        let history = historyRaw.compactMap(parseReading)

        return (current, history)
    }

    /// Event-related readings for ~14 days — the maximum history LibreLinkUp
    /// exposes beyond /graph's ~12h. Used once (or occasionally) to backfill
    /// a gap, not on the regular poll cadence: it does NOT carry a trend
    /// arrow (only /graph does), and it is not the full continuous trace —
    /// only readings LibreLinkUp associated with an alarm/event.
    func logbook() async throws -> [RawReading] {
        guard token != nil else { throw LLUError.notAuthenticated }
        guard let patientId else { throw LLUError.noPatients }

        let obj = try await call("llu/connections/\(patientId)/logbook")
        guard let rows = obj["data"] as? [[String: Any]] else {
            throw LLUError.badResponse(0, "missing data field")
        }
        return rows.compactMap(parseReading)
    }

    private func parseReading(_ obj: [String: Any]) -> RawReading? {
        guard let value = (obj["ValueInMgPerDl"] as? Double) ?? (obj["ValueInMgPerDl"] as? Int).map(Double.init),
              let tsString = obj["FactoryTimestamp"] as? String,
              let ts = Self.timestampFormatter.date(from: tsString)
        else { return nil }
        let trend = obj["TrendArrow"] as? Int
        let isHigh = (obj["isHigh"] as? Bool) ?? false
        let isLow = (obj["isLow"] as? Bool) ?? false
        return RawReading(valueMgDl: value, trend: trend, isHigh: isHigh, isLow: isLow, timestamp: ts)
    }

    var isAuthenticated: Bool { token != nil && patientId != nil }

    func signOut() {
        token = nil
        accountIdHash = nil
        patientId = nil
    }
}
