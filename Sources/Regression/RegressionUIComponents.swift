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
