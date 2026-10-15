import Foundation

/// Conservative detection of credentials and other secrets in copied text.
///
/// This is a heuristic. It catches common token formats and private keys; it cannot
/// promise to catch every secret, and the UI says so.
public enum SecretDetector {
    public enum Finding: String, Sendable, Equatable {
        case privateKey = "Private key"
        case cloudKey = "Cloud access key"
        case apiToken = "API token"
        case paymentCard = "Payment card number"
        case jwt = "Access token"
        case highEntropy = "Password-like string"
    }

    private static let patterns: [(Finding, String)] = [
        (.privateKey, #"-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----"#),
        (.cloudKey, #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        (.apiToken, #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"#),
        (.apiToken, #"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#),
        (.apiToken, #"\bsk-(ant-|proj-)?[A-Za-z0-9_\-]{24,}\b"#),
        (.apiToken, #"\bxox[abprs]-[A-Za-z0-9\-]{10,}\b"#),
        (.apiToken, #"\b(sk|rk)_live_[A-Za-z0-9]{20,}\b"#),
        (.apiToken, #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        (.jwt, #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#),
    ]

    public static func scan(_ text: String) -> Finding? {
        guard !text.isEmpty else { return nil }
        let sample = text.count > 20_000 ? String(text.prefix(20_000)) : text
        for (finding, pattern) in patterns where sample.range(of: pattern, options: .regularExpression) != nil {
            return finding
        }
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPaymentCard(trimmed) { return .paymentCard }
        if looksLikePassword(trimmed) { return .highEntropy }
        return nil
    }

    /// 13–19 digits (spaces/dashes allowed) passing the Luhn check, and nothing else.
    static func isPaymentCard(_ s: String) -> Bool {
        guard s.count <= 23 else { return false }
        let allowed = s.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }
        guard allowed else { return false }
        let digits = s.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    /// A single short token mixing character classes with high entropy — typical of a
    /// generated password. Hex digests and UUIDs are excluded because they are routinely
    /// copied and are not secret.
    static func looksLikePassword(_ s: String) -> Bool {
        guard (12...64).contains(s.count), !s.contains(where: { $0.isWhitespace }) else { return false }
        if s.allSatisfy(\.isHexDigit) { return false }
        if UUID(uuidString: s) != nil { return false }
        if s.contains("://") || s.contains("/") || s.hasPrefix("#") { return false }
        if s.contains("@") && s.contains(".") { return false }
        let hasLower = s.contains(where: \.isLowercase)
        let hasUpper = s.contains(where: \.isUppercase)
        let hasDigit = s.contains(where: \.isNumber)
        let hasSymbol = s.contains(where: { !$0.isLetter && !$0.isNumber })
        let classes = [hasLower, hasUpper, hasDigit, hasSymbol].filter { $0 }.count
        guard classes >= 3 else { return false }
        // Identifiers such as camelCase words or snake_case names are not secrets.
        if s.range(of: #"^[a-z]+([A-Z][a-z]+)+\d*$"#, options: .regularExpression) != nil { return false }
        return shannonEntropy(s) >= 3.3
    }

    static func shannonEntropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }
}

/// What to do with content that looks sensitive.
public enum SensitiveContentHandling: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Do not save it at all.
    case skip
    /// Keep it briefly on this device, then delete it.
    case keepBriefly
    /// Save it like anything else (still local-only).
    case keep

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .skip: "Don’t save"
        case .keepBriefly: "Keep for 2 minutes"
        case .keep: "Save on this device only"
        }
    }
}

/// User-configurable privacy settings that the policy engine evaluates.
public struct PrivacySettings: Codable, Sendable, Equatable {
    public var isCapturePaused: Bool = false
    public var excludedBundleIDs: Set<String> = PrivacySettings.defaultExclusions
    public var sensitiveHandling: SensitiveContentHandling = .skip
    public var honorConcealedMarkers: Bool = true
    public var maxItemBytes: Int64 = 50 * 1024 * 1024
    public var briefRetention: TimeInterval = 120

    public init() {}

    public static let defaultExclusions: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
        "com.markmcguill.strongbox.mac",
        "com.nordpass.macos.NordPass",
    ]
}

/// Pasteboard marker types that ask clipboard managers to stay away.
/// See nspasteboard.org; several password managers also use their own types.
public enum PasteboardMarkers {
    public static let concealed = "org.nspasteboard.ConcealedType"
    public static let transient = "org.nspasteboard.TransientType"
    public static let autoGenerated = "org.nspasteboard.AutoGeneratedType"
    public static let source = "org.nspasteboard.source"
    /// Written by Rekeep itself so it never re-captures its own writes.
    public static let rekeepOrigin = "app.rekeep.origin"

    public static let ignoreTypes: Set<String> = [
        concealed, transient, autoGenerated,
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type",
        "net.antelle.keeweb",
        rekeepOrigin,
    ]
}

/// The decision for one capture attempt.
public enum CaptureDecision: Equatable, Sendable {
    case store(localOnly: Bool, expiresAt: Date?)
    case ignore(IgnoreReason)
}

public enum IgnoreReason: String, Sendable, Equatable {
    case paused
    case excludedApp
    case markedConcealed
    case ownWrite
    case sensitive
    case tooLarge
    case empty
    case unsupported
}

/// Evaluated before anything is persisted, indexed, OCR'd, thumbnailed, or synced.
public struct PrivacyPolicy: Sendable {
    public var settings: PrivacySettings

    public init(settings: PrivacySettings) { self.settings = settings }

    /// First gate: evaluated before Rekeep reads any content from the pasteboard.
    public func preflight(sourceBundleID: String?, pasteboardTypes: Set<String>) -> IgnoreReason? {
        if pasteboardTypes.contains(PasteboardMarkers.rekeepOrigin) { return .ownWrite }
        if settings.isCapturePaused { return .paused }
        if let id = sourceBundleID, settings.excludedBundleIDs.contains(id) { return .excludedApp }
        if settings.honorConcealedMarkers, !pasteboardTypes.isDisjoint(with: PasteboardMarkers.ignoreTypes) { return .markedConcealed }
        if pasteboardTypes.isEmpty { return .empty }
        return nil
    }

    /// Second gate: evaluated on the extracted content, still before persistence.
    public func evaluate(text: String?, totalBytes: Int64, now: Date = .now) -> CaptureDecision {
        if totalBytes > settings.maxItemBytes { return .ignore(.tooLarge) }
        if let text, SecretDetector.scan(text) != nil {
            switch settings.sensitiveHandling {
            case .skip: return .ignore(.sensitive)
            case .keepBriefly: return .store(localOnly: true, expiresAt: now.addingTimeInterval(settings.briefRetention))
            case .keep: return .store(localOnly: true, expiresAt: nil)
            }
        }
        return .store(localOnly: false, expiresAt: nil)
    }
}
