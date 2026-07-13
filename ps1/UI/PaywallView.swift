import SwiftUI
import WebKit
import RevenueCat

/// Пейвол под альбомную ориентацию: слева бенефиты,
/// тонкий разделитель, справа цена и покупка.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manager = SubscriptionManager.shared

    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var legalDocument: LegalDocument?

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.09).ignoresSafeArea()

            HStack(spacing: 0) {
                benefitsPane
                    .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 1)
                    .padding(.vertical, 28)

                purchasePane
                    .frame(width: 300)
            }
            .padding(.horizontal, 36)

            closeButton
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .alert("Something went wrong", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $legalDocument) { document in
            LegalSheet(document: document)
        }
        .onAppear {
            if manager.package == nil {
                Task { await manager.loadOffering() }
            }
        }
    }

    // MARK: - Левая панель: бенефиты

    private var benefitsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("PRO")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("The full experience, no limits")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 14) {
                benefit(icon: "sparkles.tv",
                        title: "Enhanced Resolution",
                        subtitle: "3D rendered at double quality (×2)")
                benefit(icon: "arrow.up.left.and.arrow.down.right",
                        title: "Full-Screen Picture",
                        subtitle: "Image stretched edge to edge")
                benefit(icon: "wand.and.stars",
                        title: "Picture Smoothing",
                        subtitle: "Soft filtering instead of raw pixels")
                benefit(icon: "forward.fill",
                        title: "Fast-Forward ×2",
                        subtitle: "Hold the trigger, skip the dialogues")
                benefit(icon: "photo.on.rectangle.angled",
                        title: "Game Covers",
                        subtitle: "Real box art in your library")
            }
            .padding(.top, 24)

            Text(trialStatus)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 18)

            Spacer()
        }
        .padding(.trailing, 28)
    }

    private var trialStatus: String {
        let remaining = FeatureGate.trialRemaining
        guard remaining > 0 else {
            let totalHours = Int(FeatureGate.trialSeconds) / 3600
            return "Free trial ended — \(totalHours) free hours played"
        }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        return "Free trial: \(hours)h \(minutes)m of playtime left"
    }

    private func benefit(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text(subtitle)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Правая панель: покупка

    private var purchasePane: some View {
        VStack(spacing: 0) {
            Spacer()

            if let package = manager.package {
                Text(package.storeProduct.localizedPriceString)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("per week")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 2)
            } else {
                ProgressView()
                    .tint(.white)
                    .padding(.bottom, 8)
                Text("Loading price…")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Button(action: subscribe) {
                ZStack {
                    if isPurchasing {
                        ProgressView().tint(.black)
                    } else {
                        Text("Subscribe")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Capsule().fill(.white))
                .foregroundStyle(.black)
            }
            .disabled(isPurchasing || manager.package == nil)
            .padding(.top, 24)

            Button(action: restore) {
                if isRestoring {
                    ProgressView().tint(.white.opacity(0.6))
                } else {
                    Text("Restore Purchases")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .disabled(isRestoring)
            .padding(.top, 14)

            Text("Subscription renews automatically. Cancel anytime in your App Store settings.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .padding(.top, 18)

            HStack(spacing: 16) {
                legalLink("Terms", .terms)
                legalLink("Privacy", .privacy)
            }
            .padding(.top, 10)

            Spacer()
        }
        .padding(.leading, 28)
    }

    private func legalLink(_ title: String, _ document: LegalDocument) -> some View {
        Button {
            legalDocument = document
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .underline()
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Действия

    private func subscribe() {
        guard !isPurchasing else { return }
        isPurchasing = true
        Task {
            defer { isPurchasing = false }
            do {
                if try await manager.purchase() == .success {
                    dismiss()
                }
                // Отмена пользователем — молча остаёмся на пейволе
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restore() {
        guard !isRestoring else { return }
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                if try await manager.restore() {
                    dismiss()
                } else {
                    errorMessage = String(localized: "No active subscription found.")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Юридические документы

enum LegalDocument: String, Identifiable {
    case terms
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: "Terms of Use"
        case .privacy: "Privacy Policy"
        }
    }

    var url: URL {
        switch self {
        // Стандартный Apple EULA — для подписок этого достаточно
        case .terms: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
        case .privacy: URL(string: "https://raw.githubusercontent.com/udevwork/PS1-iOS-Emulator/refs/heads/main/PRIVACY.md")!
        }
    }
}

/// Модалка с WKWebView для условий/политики
struct LegalSheet: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebView(url: document.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(document.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
