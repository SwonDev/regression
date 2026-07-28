import AppKit
import Foundation
import Observation
import SwiftUI

enum RegressionMenuBarIconState: String, CaseIterable, Hashable {
    case ready
    case working
    case running
    case error

    init(operation: AppOperation) {
        switch operation {
        case .ready:
            self = .ready
        case .discovering, .preparing, .switching:
            self = .working
        case .running:
            self = .running
        case .error:
            self = .error
        }
    }

    fileprivate var assetName: String {
        "RegressionMenuBar-\(rawValue)"
    }
}

/// Marca estática de Regression que cambia únicamente cuando cambia el estado operativo.
struct RegressionMenuBarIcon: View {
    let state: RegressionMenuBarIconState
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: RegressionMenuBarIconStore.image(for: state))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

private enum RegressionMenuBarIconStore {
    private static let images: [RegressionMenuBarIconState: NSImage] = {
        var result: [RegressionMenuBarIconState: NSImage] = [:]
        for state in RegressionMenuBarIconState.allCases {
            guard let image = Bundle.main.image(forResource: NSImage.Name(state.assetName)) else {
                continue
            }
            // El lienzo lógico debe permanecer fijo aunque cambie la representación Retina.
            // La huella visible ya viene centrada ópticamente en el asset.
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            result[state] = image
        }
        return result
    }()

    private static let fallback: NSImage = {
        let image = NSImage(
            systemSymbolName: "r.circle",
            accessibilityDescription: "Regression"
        ) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }()

    static func image(for state: RegressionMenuBarIconState) -> NSImage {
        images[state] ?? fallback
    }
}

/// Vista decorativa que deja la interacción completa en manos de NSStatusBarButton.
final class RegressionStatusIconView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class RegressionStatusItemPresenter {
    private weak var button: NSStatusBarButton?
    private weak var iconView: NSImageView?
    private let model: RegressionAppModel
    private var displayedState: RegressionMenuBarIconState?
    private var isObserving = false

    init(
        button: NSStatusBarButton,
        iconView: NSImageView,
        model: RegressionAppModel
    ) {
        self.button = button
        self.iconView = iconView
        self.model = model
    }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        observeChanges()
    }

    func stop() {
        isObserving = false
    }

    private func observeChanges() {
        guard isObserving else { return }
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeChanges()
            }
        }
    }

    private func update() {
        guard let button, let iconView else { return }
        let state = RegressionMenuBarIconState(operation: model.operation)
        if state != displayedState {
            iconView.image = RegressionMenuBarIconStore.image(for: state)
            displayedState = state
        }
        button.toolTip = "Regression: \(model.statusTitle)"
        button.setAccessibilityLabel("Regression: \(model.statusTitle)")
    }
}
