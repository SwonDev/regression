import AppKit
import Foundation
import RegressionCore
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
  static let title3 = Self(
    standardFont: .title3,
    basePointSize: 15,
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

    var font = Font.system(
      size: specification.basePointSize * dynamicTypeSize.regressionScale,
      weight: specification.selectedWeight ?? specification.defaultWeight
    )
    if specification.usesMonospacedDigits {
      font = font.monospacedDigit()
    }
    return font
  }
}

private extension DynamicTypeSize {
  var regressionScale: CGFloat {
    switch self {
    case .accessibility1: 1.15
    case .accessibility2: 1.28
    case .accessibility3: 1.40
    case .accessibility4: 1.52
    case .accessibility5: 1.65
    default: 1
    }
  }
}

extension View {
  func regressionFont(_ specification: RegressionFontSpec) -> some View {
    modifier(RegressionAccessibleFontModifier(specification: specification))
  }

  func regressionAccessibleControl() -> some View {
    modifier(RegressionAccessibleControlModifier())
  }
}

private struct RegressionAccessibleControlModifier: ViewModifier {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  func body(content: Content) -> some View {
    content
      .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 7 : 3)
      .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 4 : 0)
      .regressionFont(.callout)
      .controlSize(dynamicTypeSize.isAccessibilitySize ? .large : .regular)
      .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 40 : 32)
      .contentShape(Rectangle())
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
            .stroke(Color.primary, lineWidth: 1.5)
        }
      }
  }
}

/// Presentación reutilizable para componentes sellados del runtime. La vista no decide rutas,
/// hashes ni reparaciones: recibe un informe ya evaluado y una acción permitida por el modelo.
/// La futura tarjeta de Apple GPTK debe reutilizar este mismo componente.
struct RegressionComponentHealthView<Actions: View>: View {
  let title: String
  let systemImage: String
  let color: Color
  let summary: String
  let detail: String?
  let isRefreshing: Bool
  let refreshingAccessibilityLabel: String
  @ViewBuilder let actions: Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Label {
          Text(title)
            .foregroundStyle(Color.primary)
        } icon: {
          Image(systemName: systemImage)
            .foregroundStyle(color)
        }
        .regressionFont(.callout.weight(.medium))
        Spacer()
        if isRefreshing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(refreshingAccessibilityLabel)
        }
      }

      Text(summary)
        .regressionFont(.caption)
        .foregroundStyle(Color.primary)
        .fixedSize(horizontal: false, vertical: true)

      if let detail {
        Text(detail)
          .regressionFont(.caption2)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      actions
    }
    .accessibilityElement(children: .contain)
  }
}

struct AppleGPTKLicenseSheet: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: RegressionAppModel
  let review: AppleGPTKLicenseReview

  @State private var confirmsLicenseReview = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Licencia de Apple GPTK \(review.source.version)")
          .regressionFont(.title3)
          .accessibilityAddTraits(.isHeader)
          .fixedSize(horizontal: false, vertical: true)
        Text(review.source.sourceDescription)
          .regressionFont(.caption)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      AppleGPTKRTFDocumentView(
        data: review.licenseRTFData,
        magnification: dynamicTypeSize.regressionScale
      )
        .frame(
          minWidth: dynamicTypeSize.isAccessibilitySize ? 548 : 540,
          idealWidth: dynamicTypeSize.isAccessibilitySize ? 652 : 540,
          minHeight: dynamicTypeSize.isAccessibilitySize ? 330 : 390,
          idealHeight: dynamicTypeSize.isAccessibilitySize ? 420 : 390
        )
        .layoutPriority(1)
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityLabel("Licencia exacta de Apple GPTK \(review.source.version)")

      Toggle(
        "He leído la licencia mostrada y confirmo expresamente su aceptación.",
        isOn: $confirmsLicenseReview
      )
      .regressionAccessibleControl()
      .fixedSize(horizontal: false, vertical: true)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          cancelButton
          Spacer(minLength: 12)
          authorizationProgress
          authorizationButton
        }

        VStack(alignment: .trailing, spacing: 8) {
          authorizationProgress
          HStack(spacing: 10) {
            cancelButton
            Spacer(minLength: 12)
            authorizationButton
          }
        }
      }
    }
    .padding(dynamicTypeSize.isAccessibilitySize ? 16 : 20)
    .frame(
      minWidth: 580,
      idealWidth: dynamicTypeSize.isAccessibilitySize ? 700 : 600,
      maxWidth: dynamicTypeSize.isAccessibilitySize ? 760 : 620,
      minHeight: dynamicTypeSize.isAccessibilitySize ? 620 : 540,
      idealHeight: dynamicTypeSize.isAccessibilitySize ? 680 : nil,
      maxHeight: dynamicTypeSize.isAccessibilitySize ? 760 : nil
    )
    .interactiveDismissDisabled()
  }

  private var cancelButton: some View {
    Button("Cancelar") {
      model.cancelAppleGPTKLicenseReview()
    }
    .keyboardShortcut(.cancelAction)
    .regressionAccessibleControl()
    .disabled(model.appleGPTKLicenseAuthorizationIsBusy)
  }

  @ViewBuilder
  private var authorizationProgress: some View {
    if model.appleGPTKLicenseAuthorizationIsBusy {
      ProgressView()
        .controlSize(dynamicTypeSize.isAccessibilitySize ? .regular : .small)
        .accessibilityLabel(
          review.source.isProtectedExisting
            ? "Autorizando Apple GPTK 3.0"
            : "Instalando Apple GPTK 4.0b2"
        )
    }
  }

  private var authorizationButton: some View {
    Button(review.source.isProtectedExisting ? "Aceptar y autorizar" : "Aceptar e instalar") {
      model.beginAppleGPTKAuthorization(
        review,
        explicitConfirmation: review.source.confirmationValue
      )
    }
    .buttonStyle(.borderedProminent)
    .keyboardShortcut(.defaultAction)
    .regressionAccessibleControl()
    .disabled(!confirmsLicenseReview || model.appleGPTKLicenseAuthorizationIsBusy)
    .accessibilityHint(
      review.source.isProtectedExisting
        ? "Crea una autorización privada de un solo uso y vuelve a verificar el componente existente sin copiar ni modificar su payload"
        : "Crea una autorización privada de un solo uso y vuelve a verificar el DMG antes de instalar"
    )
  }
}

private struct AppleGPTKRTFDocumentView: NSViewRepresentable {
  let data: Data
  let magnification: CGFloat

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    textView.textContainerInset = NSSize(width: 12, height: 12)
    scrollView.allowsMagnification = true
    scrollView.minMagnification = 1
    scrollView.maxMagnification = 1.65
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    let sourceDocument = (try? NSAttributedString(
      data: data,
      options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil
    )) ?? NSAttributedString(
      string: String(decoding: data, as: UTF8.self),
      attributes: [.foregroundColor: NSColor.labelColor]
    )
    let document = NSMutableAttributedString(attributedString: sourceDocument)
    let fullRange = NSRange(location: 0, length: document.length)
    // La licencia conserva tipografía, peso y estructura del RTF oficial,
    // pero usa colores semánticos del sistema para seguir siendo legible en
    // claro, oscuro, alto contraste e Increase Contrast.
    document.removeAttribute(.foregroundColor, range: fullRange)
    document.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
    if textView.attributedString() != document {
      textView.textStorage?.setAttributedString(document)
    }
    if abs(scrollView.magnification - magnification) > 0.01 {
      scrollView.magnification = magnification
    }
  }
}

struct RegressionStatusBadge: View {
  let title: String
  let systemImage: String
  let color: Color

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: systemImage)
        .foregroundStyle(color)
      Text(title)
        .foregroundStyle(Color.primary)
    }
      .regressionFont(.caption.weight(.semibold))
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
        .foregroundStyle(index <= activeStage ? Color.primary : Color.regressionSecondary)
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
