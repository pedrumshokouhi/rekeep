import Foundation
import Observation
import StoreKit
import SwiftUI

/// What Free includes, in one place so the UI and the limits never disagree.
enum FreeTier {
    /// Pro can be switched off for a release that ships everything free.
    static let monetizationEnabled = true
    static let visibleHistory = 200
    static let collections = 3
    static let snippets = 5
}

enum ProFeature: String, Identifiable {
    case history, collections, snippets, compose, queue
    var id: String { rawValue }
    var reason: String {
        switch self {
        case .history: "Free shows your latest \(FreeTier.visibleHistory) clips. Older clips are kept — Pro shows all of them."
        case .collections: "Free includes \(FreeTier.collections) collections."
        case .snippets: "Free includes \(FreeTier.snippets) snippets."
        case .compose: "Compose combines clips into one finished piece."
        case .queue: "The Paste Queue pastes several clips in order."
        }
    }
}

/// StoreKit 2 entitlement for the one-time Rekeep Pro unlock.
@Observable
@MainActor
final class PurchaseManager {
    static let shared = PurchaseManager()
    static let productID = "com.pedrumshokouhi.rekeep.pro"

    private(set) var product: Product?
    private(set) var isPro: Bool
    private(set) var isPurchasing = false
    private(set) var isPending = false
    private(set) var loadError: String?
    var paywallReason: ProFeature?

    private var updates: Task<Void, Never>?

    private init() {
        // Cached so Pro works offline and at launch before StoreKit answers.
        isPro = !FreeTier.monetizationEnabled || SharedStorage.defaults.bool(forKey: "rekeep.pro")
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        // Under XCTest the test installs a local StoreKit session first; don't race it.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task { await refreshEntitlement(); await loadProduct() }
        }
    }

    /// True when the feature is usable now; otherwise records why, so a paywall can explain.
    func allows(_ feature: ProFeature, count: Int = 0) -> Bool {
        if isPro { return true }
        switch feature {
        case .collections: if count < FreeTier.collections { return true }
        case .snippets: if count < FreeTier.snippets { return true }
        case .history: if count < FreeTier.visibleHistory { return true }
        case .compose, .queue: break
        }
        paywallReason = feature
        return false
    }

    var historyLimit: Int? { isPro ? nil : FreeTier.visibleHistory }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
            loadError = product == nil ? "Rekeep Pro isn’t available right now." : nil
        } catch {
            loadError = "Couldn’t reach the App Store."
        }
    }

    func purchase() async {
        guard let product else { await loadProduct(); return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlement()
                    paywallReason = nil
                }
            case .pending:
                isPending = true
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            loadError = "The purchase didn’t go through. You haven’t been charged."
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlement()
        if isPro { paywallReason = nil }
    }

    /// Reads current entitlements; refunds and revocations remove access (data is never deleted).
    func refreshEntitlement() async {
        guard FreeTier.monetizationEnabled else { isPro = true; return }
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil {
                owned = true
            }
        }
        isPro = owned
        isPending = isPending && !owned
        SharedStorage.defaults.set(owned, forKey: "rekeep.pro")
    }
}

/// The quiet paywall: clear benefits, legible price, visible dismissal, no urgency.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PurchaseManager.shared
    var reason: ProFeature?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                        .frame(width: 30, height: 30).background(Palette.chipFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            VStack(spacing: 18) {
                BrandMarkTwoTone(size: 54)
                VStack(spacing: 6) {
                    Text("Rekeep Pro").font(.system(size: 28, weight: .semibold))
                    if let reason {
                        Text(reason.reason).font(.callout).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    benefit("clock.arrow.circlepath", "Your whole history", "Every clip you’ve ever kept, searchable.")
                    benefit("square.stack", "Unlimited collections and snippets", "Organise everything you reuse.")
                    benefit("square.and.pencil", "Compose", "Turn selected clips into briefs, emails, and reference lists.")
                    benefit("list.number", "Paste Queue", "Paste a series of clips in order.")
                }
                .padding(.vertical, 6)

                if store.isPro {
                    Label("Pro is unlocked. Thank you.", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.jadeInk).font(.headline)
                } else {
                    Button {
                        Task { await store.purchase() }
                    } label: {
                        Group {
                            if store.isPurchasing { ProgressView().controlSize(.small) }
                            else if let product = store.product { Text("Unlock Pro — \(product.displayPrice)") }
                            else { Text("Unlock Pro") }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.jade)
                    .controlSize(.large)
                    .disabled(store.isPurchasing)
                    Text("One-time purchase. No subscription. Unlocks Pro on your Mac, iPhone, and iPad with the same Apple Account.")
                        .font(.caption).foregroundStyle(Palette.inkTertiary).multilineTextAlignment(.center)
                    if store.isPending {
                        Text("Your purchase is waiting for approval. Pro unlocks as soon as it’s approved.").font(.caption).foregroundStyle(Palette.inkSecondary)
                    }
                    if let error = store.loadError {
                        Text(error).font(.caption).foregroundStyle(Palette.danger)
                    }
                    HStack(spacing: 18) {
                        Button("Restore Purchase") { Task { await store.restore() } }
                        Link("Privacy", destination: URL(string: "https://pedrumshokouhi.com/rekeep/privacy")!)
                        Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .tint(Palette.inkSecondary)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(24)
        .frame(maxWidth: 440)
        .task { if store.product == nil { await store.loadProduct() } }
    }

    private func benefit(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.jadeInk).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(.caption).foregroundStyle(Palette.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
