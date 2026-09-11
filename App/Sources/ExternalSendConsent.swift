import StenoIntelligence

/// Consent follows the full destination configuration, not a session Boolean.
/// A changed endpoint must be shown again, including changes while a sheet is open.
struct ExternalSendConsent {
    private(set) var acknowledged: TextModelEndpoint?
    private(set) var pending: TextModelEndpoint?

    func permits(_ endpoint: TextModelEndpoint?) -> Bool {
        endpoint == nil || endpoint == acknowledged
    }

    mutating func prepare(_ endpoint: TextModelEndpoint?) {
        pending = endpoint
    }

    mutating func accept(current endpoint: TextModelEndpoint?) -> Bool {
        defer { pending = nil }
        guard let pending, pending == endpoint else { return false }
        acknowledged = pending
        return true
    }
}
