import SwiftUI

extension ShapeStyle where Self == Color {
  /// Jerarquía secundaria con contraste suficiente sobre las tarjetas claras del popover.
  static var regressionSecondary: Color { .primary.opacity(0.72) }
}

/// Conserva exactamente los estilos semánticos de SwiftUI en el tamaño normal y les añade una
/// respuesta explícita a los tamaños de accesibilidad que macOS expone en el entorno. SwiftUI no
/// escala visualmente estos estilos en todos los hosts de macOS, así que el popover no puede
/// depender solo de `dynamicTypeSize(_:)` para demostrar adaptación.
struct RegressionFontSpec {
  fileprivate var standardFont: Font
  fileprivate let basePointSize: CGFloat
  fileprivate let defaultWeight: Font.Weight
  fileprivate var selectedWeight: Font.Weight?
  fileprivate var usesMonospacedDigits = false

  static let caption2 = Self(
    standardFont: .caption2,
    basePointSize: 11,
    defaultWeight: .regular
  )
  static let caption = Self(
    standardFont: .caption,
    basePointSize: 12,
    defaultWeight: .regular
  )
  static let callout = Self(
    standardFont: .callout,
    basePointSize: 13,
    defaultWeight: .regular
  )
  static let headline = Self(
    standardFont: .headline,
    basePointSize: 13,
    defaultWeight: .semibold
  )

  func weight(_ weight: Font.Weight) -> Self {
    var copy = self
    copy.selectedWeight = weight
    copy.standardFont = standardFont.weight(weight)
    return copy
  }

  func monospacedDigit() -> Self {
    var copy = self
    copy.usesMonospacedDigits = true
    copy.standardFont = standardFont.monospacedDigit()
    return copy
  }
}

private struct RegressionAccessibleFontModifier: ViewModifier {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let specification: RegressionFontSpec

  func body(content: Content) -> some View {
    content.font(resolvedFont)
  }

  private var resolvedFont: Font {
    guard dynamicTypeSize.isAccessibilitySize else {
      return specification.standardFont
    }

    let scale: CGFloat =
      switch dynamicTypeSize {
      case .accessibility1: 1.15
      case .accessibility2: 1.28
      case .accessibility3: 1.40
      case .accessibility4: 1.52
      case .accessibility5: 1.65
      default: 1
      }
    var font = Font.system(
      size: specification.basePointSize * scale,
      weight: specification.selectedWeight ?? specification.defaultWeight
    )
    if specification.usesMonospacedDigits {
      font = font.monospacedDigit()
    }
    return font
  }
}

extension View {
  func regressionFont(_ specification: RegressionFontSpec) -> some View {
    modifier(RegressionAccessibleFontModifier(specification: specification))
  }
}

struct RegressionCard<Content: View>: View {
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color(nsColor: .controlBackgroundColor)
          .opacity(colorSchemeContrast == .increased ? 1 : 0.82),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay {
        if colorSchemeContrast == .increased {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.primary, lineWidth: 1.5)
        }
      }
  }
}

struct RegressionStatusBadge: View {
  let title: String
  let systemImage: String
  let color: Color

  var body: some View {
    Label(title, systemImage: systemImage)
      .regressionFont(.caption.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        color.opacity(0.13),
        in: Capsule(style: .continuous)
      )
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Estado: \(title)")
  }
}

enum LibraryIndependenceState: Equatable {
  case eligible
  case preparing
  case preCutover
  case cutover
  case verifying
  case pendingValidation
  case validating
  case rollingBack
  case error(String)
  case independent

  var isBusy: Bool {
    switch self {
    case .preparing, .cutover, .verifying, .validating, .rollingBack: true
    case .eligible, .preCutover, .pendingValidation, .error, .independent: false
    }
  }

  var hidesLegacyOperations: Bool {
    switch self {
    case .cutover, .verifying, .pendingValidation, .validating, .rollingBack, .error,
      .independent:
      true
    case .eligible, .preparing, .preCutover: false
    }
  }

  var blocksNormalOperations: Bool {
    switch self {
    case .preparing, .preCutover, .cutover, .verifying, .pendingValidation, .validating,
      .rollingBack:
      true
    case .eligible, .independent:
      false
    case .error:
      true
    }
  }

  var allowsValidationGameLaunch: Bool {
    self == .validating
  }

  var requiresMigrationResume: Bool {
    switch self {
    case .preparing, .preCutover, .cutover, .verifying: true
    case .eligible, .pendingValidation, .validating, .rollingBack, .error, .independent: false
    }
  }

  var accessibilityValue: String {
    switch self {
    case .eligible: "Preparado para revisar el traslado"
    case .preparing: "Inventariando la biblioteca"
    case .preCutover: "Esperando confirmación"
    case .cutover: "Trasladando la biblioteca"
    case .verifying: "Verificando archivos y manifiestos"
    case .pendingValidation: "Esperando validación con Steam"
    case .validating: "Validando Steam y juegos con Regression"
    case .rollingBack: "Restaurando el estado anterior"
    case .error: "Necesita atención"
    case .independent: "Independencia validada"
    }
  }
}

struct RegressionCustodyProgress: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let state: LibraryIndependenceState

  private let stages = ["Inventario", "Traslado", "Integridad", "Validación"]

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        verticalProgress
      } else {
        ViewThatFits(in: .horizontal) {
          compactProgress
          verticalProgress
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Progreso de independencia")
    .accessibilityValue(state.accessibilityValue)
  }

  private var compactProgress: some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
      GridRow {
        stageLabel(index: 0, title: stages[0])
        stageLabel(index: 1, title: stages[1])
      }
      GridRow {
        stageLabel(index: 2, title: stages[2])
        stageLabel(index: 3, title: stages[3])
      }
    }
  }

  private var verticalProgress: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(Array(stages.enumerated()), id: \.offset) { index, title in
        stageLabel(index: index, title: title)
      }
    }
  }

  private func stageLabel(index: Int, title: String) -> some View {
    Label {
      Text(title)
        .regressionFont(.caption2.weight(index == activeStage ? .semibold : .regular))
        .foregroundStyle(index <= activeStage ? Color.primary : .regressionSecondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    } icon: {
      Image(systemName: symbol(for: index))
        .foregroundStyle(color(for: index))
    }
  }

  private var activeStage: Int {
    switch state {
    case .eligible, .preparing, .preCutover, .error: 0
    case .cutover: 1
    case .verifying, .rollingBack: 2
    case .pendingValidation, .validating, .independent: 3
    }
  }

  private func symbol(for index: Int) -> String {
    if case .error = state, index == activeStage { return "exclamationmark.circle.fill" }
    if case .rollingBack = state, index == activeStage { return "arrow.uturn.backward.circle.fill" }
    if index < activeStage || state == .independent { return "checkmark.circle.fill" }
    if index == activeStage && state.isBusy { return "circle.dotted" }
    return "circle"
  }

  private func color(for index: Int) -> Color {
    if case .error = state, index == activeStage { return .red }
    if case .rollingBack = state, index == activeStage { return .orange }
    if index < activeStage || state == .independent { return .green }
    return index == activeStage ? .accentColor : .secondary
  }
}
