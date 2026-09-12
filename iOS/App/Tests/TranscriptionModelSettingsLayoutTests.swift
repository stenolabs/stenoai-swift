import Foundation
import StenoDomain
import StenoPipeline
import SwiftUI
import Testing
import UIKit
@testable import Steno

@Suite("Transcription model settings layout", .serialized)
@MainActor
struct TranscriptionModelSettingsLayoutTests {
    @Test("installation progress stacks at accessibility text sizes")
    func installationProgressUsesAdaptiveAxis() {
        #expect(
            IOSModelInstallationProgressLayout.axis(for: .large)
                == .horizontal
        )
        #expect(
            IOSModelInstallationProgressLayout.axis(for: .accessibility1)
                == .vertical
        )
        #expect(
            IOSModelInstallationProgressLayout.axis(for: .accessibility5)
                == .vertical
        )
    }

    @Test(
        "installed offline model uses a normal list row",
        arguments: [
            CGSize(width: 393, height: 852),
            CGSize(width: 1_024, height: 1_366),
        ]
    )
    func installedOfflineModelUsesNormalListRow(size: CGSize) async throws {
        let defaultsName = "TranscriptionModelSettingsLayout-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let installer = IOSModelInstallationState(
            coordinator: ModelInstallationCoordinator(installers: [
                InstalledTranscriptionModelInstaller(),
            ]),
            consent: ModelConsent(defaults: defaults, key: "installed")
        )
        let app = AppModel(transcriptionModelInstaller: installer)
        await installer.refresh(for: app.language.locale)

        let controller = UIHostingController(
            rootView: NavigationStack {
                TranscriptionModelSettingsView()
            }
            .environment(app)
            .environment(\.dynamicTypeSize, .large)
        )
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        controller.view.layoutIfNeeded()

        let collectionView = try #require(
            descendantViews(of: controller.view).compactMap { $0 as? UICollectionView }.first
        )
        let offlineModelCell = try #require(
            collectionView.cellForItem(at: IndexPath(item: 0, section: 1))
        )

        #expect(offlineModelCell.bounds.height < 80)
    }
}

private actor InstalledTranscriptionModelInstaller: ModelInstalling {
    nonisolated let bundleDescription = ModelBundleDescription(
        id: .parakeetTDTv3,
        title: "FluidAudio Parakeet TDT",
        source: .huggingFace,
        approximateBytes: 483_307_520
    )

    func readiness(for locales: [Locale]) -> ModelReadiness {
        ModelReadiness(installed: Set(locales), missing: [:])
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {}

    func cancelInstall() async {}
}

@MainActor
private func descendantViews(of root: UIView) -> [UIView] {
    [root] + root.subviews.flatMap(descendantViews)
}
