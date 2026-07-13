import Foundation
import Observation
import RevenueCat

/// Состояние подписки поверх RevenueCat: единая точка правды для isSubscribed.
@Observable
final class SubscriptionManager {

    static let shared = SubscriptionManager()

    private static let apiKey = "appl_CHYVccOgLVtfoTiYnFklplGsBcN"
    private static let entitlementID = "nagori.ent.pro"
    private static let offeringID = "nagori.offer"

    /// Активна ли подписка. Обновляется на старте, после покупки/restore
    /// и при любых изменениях со стороны RevenueCat (продление, refund).
    private(set) var isSubscribed = false

    /// Пакет недельной подписки из оффера — цена/период для пейвола
    private(set) var package: Package?

    enum PurchaseOutcome { case success, cancelled }

    private init() {}

    /// Вызывается один раз при старте приложения.
    static func configure() {
        Purchases.configure(withAPIKey: apiKey)
        shared.startObserving()
        Task { await shared.loadOffering() }
    }

    private func startObserving() {
        Task { [weak self] in
            // Стрим шлёт актуальный CustomerInfo сразу и на каждое изменение
            for await info in Purchases.shared.customerInfoStream {
                self?.apply(info)
            }
        }
    }

    private func apply(_ info: CustomerInfo) {
        isSubscribed = info.entitlements[Self.entitlementID]?.isActive == true
        // Зеркало для FeatureGate: его читают эмуляционный и рендер-потоки
        UserDefaults.standard.set(isSubscribed, forKey: FeatureGate.subscribedCacheKey)
    }

    func loadOffering() async {
        do {
            let offerings = try await Purchases.shared.offerings()
            let offering = offerings.offering(identifier: Self.offeringID) ?? offerings.current
            package = offering?.availablePackages.first
        } catch {
            NSLog("SubscriptionManager: failed to load offering: \(error)")
        }
    }

    func purchase() async throws -> PurchaseOutcome {
        guard let package else {
            throw NSError(domain: "SubscriptionManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Subscription is unavailable. Check your connection and try again."
            ])
        }
        let result = try await Purchases.shared.purchase(package: package)
        apply(result.customerInfo)
        return result.userCancelled ? .cancelled : .success
    }

    /// Восстановление покупок. Возвращает true, если подписка нашлась.
    func restore() async throws -> Bool {
        let info = try await Purchases.shared.restorePurchases()
        apply(info)
        return isSubscribed
    }
}
