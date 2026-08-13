import Darwin
import CryptoKit
import Foundation

/// Identidad inmutable de una generación autorizada del entorno de evaluación de Apple.
///
/// El catálogo no descarga ni instala nada. Sus huellas permiten que UI, tokens y scripts
/// nombren el mismo componente sin tratar dos generaciones de D3DMetal como intercambiables.
public struct AppleGPTKComponentManifest: Equatable, Sendable {
  public let version: String
  public let dmgFileName: String?
  /// `nil` impide onboarding desde DMG hasta que la distribución exacta quede demostrada.
  public let dmgSHA256: String?
  public let minimumMacOSMajorVersion: Int
  public let d3dMetalSHA256: String
  public let d3dSharedSHA256: String

  public init(
    version: String,
    dmgFileName: String?,
    dmgSHA256: String?,
    minimumMacOSMajorVersion: Int,
    d3dMetalSHA256: String,
    d3dSharedSHA256: String
  ) {
    self.version = version
    self.dmgFileName = dmgFileName
    self.dmgSHA256 = dmgSHA256
    self.minimumMacOSMajorVersion = minimumMacOSMajorVersion
    self.d3dMetalSHA256 = d3dMetalSHA256
    self.d3dSharedSHA256 = d3dSharedSHA256
  }

  public var licenseConfirmation: String {
    "ACEPTO LA LICENCIA DE APPLE GPTK \(version)"
  }

  public var supportsDMGOnboarding: Bool {
    dmgFileName != nil && dmgSHA256 != nil
  }
}

public enum AppleGPTKComponentCatalog {
  public static let protectedProfilesComponentID = "apple-gptk-protected-profiles"
  public static let protectedProfilesPayloadFingerprint =
    "fdc07beb364b2327896196e214996585fbcc1a10c71784d383218d2de9db57d7"
  /// Generación que protegió las matrices de Grim Dawn, DragonSword y Dragon's Dogma 2.
  /// La identidad procede del expediente canónico local: D3DMetal declara 3.0 y está firmado
  /// por Apple. No debe confundirse con el D3DMetal 2.1 observado en bundles posteriores.
  public static let protectedProfiles = AppleGPTKComponentManifest(
    version: "3.0",
    dmgFileName: nil,
    dmgSHA256: nil,
    minimumMacOSMajorVersion: 14,
    d3dMetalSHA256: "05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8",
    d3dSharedSHA256: "5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995"
  )

  /// Generación moderna fijada para los perfiles que la solicitan explícitamente.
  public static let current = AppleGPTKComponentManifest(
    version: "4.0b2",
    dmgFileName: "Evaluation_environment_for_Windows_games_4.0_beta_2.dmg",
    dmgSHA256: "6248a0edc61553790753e5e9c060b8e53c940ed197f11409dcc34a35e05becc1",
    minimumMacOSMajorVersion: 15,
    d3dMetalSHA256: "f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad",
    d3dSharedSHA256: "1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0"
  )

  public static let supported = [protectedProfiles, current]
  public static let protectedProfilesUnixModuleNames = [
    "atidxx64", "d3d11", "d3d12", "dxgi", "nvapi64", "nvngx",
  ]
  public static let protectedProfilesUnixAliasTarget =
    "../../external/libd3dshared.dylib"

  public static func component(version: String) -> AppleGPTKComponentManifest? {
    supported.first { $0.version == version }
  }

  /// Sella los bytes únicos regulares del payload 3.0 protegido.
  ///
  /// Los seis módulos Unix son enlaces relativos a `external/libd3dshared.dylib`; el instalador
  /// valida esa topología. No se incluyen como archivos porque `TrustedComponentFileSetDescriptor`
  /// rechaza symlinks deliberadamente y nunca debe seguirlos durante una comprobación de salud.
  public static func protectedProfilesDescriptor(
    rootURL: URL
  ) -> TrustedComponentFileSetDescriptor {
    TrustedComponentFileSetDescriptor(
      identity: ComponentIdentity(
        componentID: protectedProfilesComponentID,
        componentVersion: protectedProfiles.version,
        variant: .publicInstalled,
        buildIdentifier: "apple-d3dmetal-3.0"
      ),
      payloadRootURL: rootURL.standardizedFileURL,
      files: protectedProfilesRegularFiles,
      maximumFileBytes: 64 * 1_024 * 1_024,
      maximumPayloadBytes: 128 * 1_024 * 1_024
    )
  }

  /// Verifica conjuntamente los bytes protegidos y los alias Unix del componente 3.0.
  ///
  /// Es una lectura local acotada: no consulta recibos, no ejecuta scripts y no sigue enlaces.
  public static func protectedProfilesHealth(rootURL: URL) -> ComponentHealthReport {
    protectedProfilesHealth(
      descriptor: protectedProfilesDescriptor(rootURL: rootURL)
    )
  }

  static func protectedProfilesHealth(
    descriptor: TrustedComponentFileSetDescriptor,
    afterFileSetEvaluation: () -> Void = {}
  ) -> ComponentHealthReport {
    guard let root = ProtectedProfilesAliasRoot.open(descriptor.payloadRootURL) else {
      return protectedProfilesAliasFailure(
        descriptor,
        issue: .payloadIsNotARegularDirectory
      )
    }
    let fileSetReport = root.evaluateFileSet(descriptor)
    guard fileSetReport.status == .ready else { return fileSetReport }
    afterFileSetEvaluation()
    guard root.isStillNamedBy(descriptor.payloadRootURL), root.validatePinnedEntries() else {
      return protectedProfilesAliasFailure(
        descriptor,
        issue: .payloadIsNotARegularDirectory
      )
    }
    for module in protectedProfilesUnixModuleNames {
      let relativePath = "wine/x86_64-unix/\(module).so"
      switch root.validateSymbolicLink(
        relativePath: relativePath,
        expectedTarget: protectedProfilesUnixAliasTarget
      ) {
      case .valid:
        continue
      case .missing:
        return protectedProfilesAliasFailure(
          descriptor,
          issue: .payloadEntryMissing(relativePath)
        )
      case .notSymbolicLink:
        return protectedProfilesAliasFailure(
          descriptor,
          issue: .payloadEntryIsNotRegularFile(relativePath)
        )
      case .wrongTarget, .changed:
        return protectedProfilesAliasFailure(
          descriptor,
          issue: .payloadDigestMismatch(relativePath)
        )
      }
    }
    guard root.isStillNamedBy(descriptor.payloadRootURL), root.validatePinnedEntries() else {
      return protectedProfilesAliasFailure(
        descriptor,
        issue: .payloadIsNotARegularDirectory
      )
    }
    return fileSetReport
  }

  private static func protectedProfilesAliasFailure(
    _ descriptor: TrustedComponentFileSetDescriptor,
    issue: ComponentHealthIssue
  ) -> ComponentHealthReport {
    ComponentHealthReport(
      identity: descriptor.identity,
      status: .drifted,
      recovery: .provideUserSource,
      issue: issue
    )
  }

  private static let protectedProfilesRegularFiles: [TrustedComponentFile] = [
    TrustedComponentFile(
      relativePath: "external/D3DMetal.framework/Versions/A/D3DMetal",
      expectedSHA256: "05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8"
    ),
    TrustedComponentFile(
      relativePath: "external/libd3dshared.dylib",
      expectedSHA256: "5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995"
    ),
    TrustedComponentFile(
      relativePath: "wine/x86_64-windows/atidxx64.dll",
      expectedSHA256: "c999c40698b7fc23c864165fb1364e6a40a8572469775947845afd42f4dfc9e7"
    ),
    TrustedComponentFile(
      relativePath: "wine/x86_64-windows/d3d11.dll",
      expectedSHA256: "7c2bfeb66b18e3ec10c3ee92c9d42f4e3123692d568d14c831aec1a13aa03f79"
    ),
    TrustedComponentFile(
      relativePath: "wine/x86_64-windows/d3d12.dll",
      expectedSHA256: "bbda1c4e94ee70255c528c5689b28333ca9bece2d755ede7c4197977a534704f"
    ),
    TrustedComponentFile(
      relativePath: "wine/x86_64-windows/dxgi.dll",
      expectedSHA256: "1b1f2d80349e043e6c628b515ba6b44478a1209c504e6c9f3dae4a9d1b06d561"
    ),
    TrustedComponentFile(
      relativePath: "wine/x86_64-windows/nvapi64.dll",
      expectedSHA256: "f073fc2377b305380bcd8c228394e48abe1caf09116e12875cb656774a14b4dc"
    ),
    TrustedComponentFile(
      relativePath: "wine/x86_64-windows/nvngx.dll",
      expectedSHA256: "d7c0df74d9bb4de5e2a3cc357b2309148fd3fdc824fe7941e4d789dbd072ff99"
    ),
  ]
}

private enum ProtectedProfilesAliasValidation {
  case valid
  case missing
  case notSymbolicLink
  case wrongTarget
  case changed
}

private struct ProtectedProfilesAliasIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
  let mode: mode_t
  let size: off_t
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
  let changedSeconds: Int
  let changedNanoseconds: Int

  init(_ metadata: stat) {
    device = metadata.st_dev
    inode = metadata.st_ino
    mode = metadata.st_mode
    size = metadata.st_size
    modifiedSeconds = metadata.st_mtimespec.tv_sec
    modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
    changedSeconds = metadata.st_ctimespec.tv_sec
    changedNanoseconds = metadata.st_ctimespec.tv_nsec
  }
}

private final class ProtectedProfilesAliasRoot {
  private static let maximumTargetBytes = 4_096
  private let descriptor: Int32
  private let identity: ProtectedProfilesAliasIdentity
  private var pinnedEntries: [ProtectedProfilesPinnedEntry] = []

  private init(descriptor: Int32, identity: ProtectedProfilesAliasIdentity) {
    self.descriptor = descriptor
    self.identity = identity
  }

  deinit {
    Darwin.close(descriptor)
  }

  static func open(_ url: URL) -> ProtectedProfilesAliasRoot? {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { return nil }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR
    else {
      Darwin.close(descriptor)
      return nil
    }
    return ProtectedProfilesAliasRoot(
      descriptor: descriptor,
      identity: ProtectedProfilesAliasIdentity(metadata)
    )
  }

  func isStillNamedBy(_ url: URL) -> Bool {
    guard let current = Self.open(url) else { return false }
    return current.identity == identity
  }

  func evaluateFileSet(
    _ fileSet: TrustedComponentFileSetDescriptor
  ) -> ComponentHealthReport {
    pinnedEntries.removeAll()
    var totalBytes: Int64 = 0
    for file in fileSet.files {
      let remainingPayloadBytes = fileSet.maximumPayloadBytes - totalBytes
      guard remainingPayloadBytes >= 0 else {
        return fileSetFailure(
          fileSet,
          issue: .payloadEntryExceedsLimit(file.relativePath)
        )
      }

      let digest: (sha256: String, byteCount: Int64)
      do {
        digest = try hashRegularFile(
          relativePath: file.relativePath,
          maximumBytes: min(fileSet.maximumFileBytes, remainingPayloadBytes)
        )
      } catch let error as ProtectedProfilesAnchoredFileError {
        let issue: ComponentHealthIssue
        switch error {
        case .symbolicLink:
          issue = .payloadEntryIsSymbolicLink(file.relativePath)
        case .notDirectory, .notRegularFile:
          issue = .payloadEntryIsNotRegularFile(file.relativePath)
        case .exceedsBudget:
          issue = .payloadEntryExceedsLimit(file.relativePath)
        case .changedDuringRead:
          issue = .payloadDigestMismatch(file.relativePath)
        case .invalidPath, .unreadable:
          issue = .payloadEntryMissing(file.relativePath)
        }
        return fileSetFailure(fileSet, issue: issue)
      } catch {
        return fileSetFailure(
          fileSet,
          issue: .payloadEntryMissing(file.relativePath)
        )
      }

      guard totalBytes <= fileSet.maximumPayloadBytes - digest.byteCount else {
        return fileSetFailure(
          fileSet,
          issue: .payloadEntryExceedsLimit(file.relativePath)
        )
      }
      totalBytes += digest.byteCount
      guard digest.sha256 == file.expectedSHA256 else {
        return fileSetFailure(
          fileSet,
          issue: .payloadDigestMismatch(file.relativePath)
        )
      }
    }
    return ComponentHealthReport(
      identity: fileSet.identity,
      status: .ready,
      recovery: .none
    )
  }

  func validateSymbolicLink(
    relativePath: String,
    expectedTarget: String
  ) -> ProtectedProfilesAliasValidation {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      return .missing
    }

    var parent = descriptor
    var localPins: [ProtectedProfilesPinnedEntry] = []
    for component in components.dropLast() {
      let name = String(component)
      let next = name.withCString {
        Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard next >= 0 else { return .missing }
      var metadata = stat()
      guard Darwin.fstat(next, &metadata) == 0 else {
        Darwin.close(next)
        return .missing
      }
      localPins.append(
        ProtectedProfilesPinnedEntry(
          parentDescriptor: parent,
          name: name,
          descriptor: next,
          identity: ProtectedProfilesAliasIdentity(metadata)
        )
      )
      parent = next
    }

    let name = String(components.last!)
    var before = stat()
    let beforeStatus = name.withCString {
      Darwin.fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW)
    }
    guard beforeStatus == 0 else { return .missing }
    guard before.st_mode & S_IFMT == S_IFLNK else { return .notSymbolicLink }

    var buffer = [CChar](repeating: 0, count: Self.maximumTargetBytes)
    let count = name.withCString {
      Darwin.readlinkat(parent, $0, &buffer, buffer.count)
    }
    guard count >= 0, count < buffer.count else { return .wrongTarget }
    let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
    guard String(bytes: bytes, encoding: .utf8) == expectedTarget else {
      return .wrongTarget
    }

    var after = stat()
    let afterStatus = name.withCString {
      Darwin.fstatat(parent, $0, &after, AT_SYMLINK_NOFOLLOW)
    }
    guard afterStatus == 0,
      ProtectedProfilesAliasIdentity(before) == ProtectedProfilesAliasIdentity(after)
    else {
      return .changed
    }
    localPins.append(
      ProtectedProfilesPinnedEntry(
        parentDescriptor: parent,
        name: name,
        descriptor: nil,
        identity: ProtectedProfilesAliasIdentity(after)
      )
    )
    pinnedEntries.append(contentsOf: localPins)
    return .valid
  }

  func validatePinnedEntries() -> Bool {
    pinnedEntries.allSatisfy { $0.isStillNamedAndUnchanged() }
  }

  private func hashRegularFile(
    relativePath: String,
    maximumBytes: Int64
  ) throws -> (sha256: String, byteCount: Int64) {
    guard maximumBytes >= 0 else {
      throw ProtectedProfilesAnchoredFileError.exceedsBudget
    }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw ProtectedProfilesAnchoredFileError.invalidPath
    }

    var parent = descriptor
    var localPins: [ProtectedProfilesPinnedEntry] = []
    for component in components.dropLast() {
      let name = String(component)
      try rejectSymbolicLink(name: name, parent: parent)
      let next = name.withCString {
        Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard next >= 0 else {
        throw ProtectedProfilesAnchoredFileError.notDirectory
      }
      var metadata = stat()
      guard Darwin.fstat(next, &metadata) == 0 else {
        Darwin.close(next)
        throw ProtectedProfilesAnchoredFileError.unreadable
      }
      localPins.append(
        ProtectedProfilesPinnedEntry(
          parentDescriptor: parent,
          name: name,
          descriptor: next,
          identity: ProtectedProfilesAliasIdentity(metadata)
        )
      )
      parent = next
    }

    let name = String(components.last!)
    try rejectSymbolicLink(name: name, parent: parent)
    let file = name.withCString {
      Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    }
    guard file >= 0 else {
      if errno == ELOOP { throw ProtectedProfilesAnchoredFileError.symbolicLink }
      throw ProtectedProfilesAnchoredFileError.unreadable
    }

    var beforeMetadata = stat()
    guard Darwin.fstat(file, &beforeMetadata) == 0 else {
      Darwin.close(file)
      throw ProtectedProfilesAnchoredFileError.unreadable
    }
    let before = ProtectedProfilesAliasIdentity(beforeMetadata)
    guard beforeMetadata.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(file)
      throw ProtectedProfilesAnchoredFileError.notRegularFile
    }
    guard beforeMetadata.st_size >= 0, beforeMetadata.st_size <= maximumBytes else {
      Darwin.close(file)
      throw ProtectedProfilesAnchoredFileError.exceedsBudget
    }

    var hasher = SHA256()
    var bytesRead: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = Darwin.read(file, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        Darwin.close(file)
        throw ProtectedProfilesAnchoredFileError.unreadable
      }
      guard bytesRead <= maximumBytes - Int64(count) else {
        Darwin.close(file)
        throw ProtectedProfilesAnchoredFileError.exceedsBudget
      }
      bytesRead += Int64(count)
      hasher.update(data: Data(buffer[0..<count]))
    }

    var afterMetadata = stat()
    guard Darwin.fstat(file, &afterMetadata) == 0,
      ProtectedProfilesAliasIdentity(afterMetadata) == before,
      bytesRead == beforeMetadata.st_size
    else {
      Darwin.close(file)
      throw ProtectedProfilesAnchoredFileError.changedDuringRead
    }
    localPins.append(
      ProtectedProfilesPinnedEntry(
        parentDescriptor: parent,
        name: name,
        descriptor: file,
        identity: before
      )
    )
    pinnedEntries.append(contentsOf: localPins)
    return (
      hasher.finalize().map { String(format: "%02x", $0) }.joined(),
      bytesRead
    )
  }

  private func rejectSymbolicLink(name: String, parent: Int32) throws {
    var metadata = stat()
    let status = name.withCString {
      Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard status == 0 else { throw ProtectedProfilesAnchoredFileError.unreadable }
    if metadata.st_mode & S_IFMT == S_IFLNK {
      throw ProtectedProfilesAnchoredFileError.symbolicLink
    }
  }

  private func fileSetFailure(
    _ fileSet: TrustedComponentFileSetDescriptor,
    issue: ComponentHealthIssue
  ) -> ComponentHealthReport {
    ComponentHealthReport(
      identity: fileSet.identity,
      status: .drifted,
      recovery: .provideUserSource,
      issue: issue
    )
  }
}

private final class ProtectedProfilesPinnedEntry {
  private let parentDescriptor: Int32
  private let name: String
  private let descriptor: Int32?
  private let identity: ProtectedProfilesAliasIdentity

  init(
    parentDescriptor: Int32,
    name: String,
    descriptor: Int32?,
    identity: ProtectedProfilesAliasIdentity
  ) {
    self.parentDescriptor = parentDescriptor
    self.name = name
    self.descriptor = descriptor
    self.identity = identity
  }

  deinit {
    if let descriptor { Darwin.close(descriptor) }
  }

  func isStillNamedAndUnchanged() -> Bool {
    var namedMetadata = stat()
    let status = name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &namedMetadata, AT_SYMLINK_NOFOLLOW)
    }
    guard status == 0, ProtectedProfilesAliasIdentity(namedMetadata) == identity else {
      return false
    }
    guard let descriptor else { return true }
    var openedMetadata = stat()
    return Darwin.fstat(descriptor, &openedMetadata) == 0
      && ProtectedProfilesAliasIdentity(openedMetadata) == identity
  }
}

private enum ProtectedProfilesAnchoredFileError: Error {
  case invalidPath
  case symbolicLink
  case notDirectory
  case notRegularFile
  case exceedsBudget
  case changedDuringRead
  case unreadable
}

public enum AppleGPTKOnboardingState: Equatable, Sendable {
  case ready
  case requiresDownload
  case requiresSelection
  case requiresLicense
  case unsupported(reason: String)
  case verifying
  case installing
  case failed(message: String)
}

public enum AppleGPTKOnboardingAction: Equatable, Sendable {
  case openOfficialDownload
  case selectDMG
  case reviewLicense
  case install
  case retry
}

public enum AppleGPTKPlatformSupport: Equatable, Sendable {
  case supported
  case unsupported(reason: String)
}

public enum AppleGPTKComponentHealth: Equatable, Sendable {
  case ready
  case missing
  case invalid(reason: String)
}

public enum AppleGPTKDMGSelection: Equatable, Sendable {
  case notDownloaded
  case availableForSelection
  case selected(URL)
}

public enum AppleGPTKLicenseConfirmation: Equatable, Sendable {
  case notReviewed
  case confirmed
}

public enum AppleGPTKOnboardingOperation: Equatable, Sendable {
  case idle
  case verifying
  case installing
  case failed(message: String)
}

/// Resultado acotado de `install-apple-gptk-component --status`.
///
/// La app solo acepta los prefijos estables que emite el instalador incluido. El texto libre
/// nunca elige rutas, versiones ni acciones de instalación.
public enum AppleGPTKInstallerStatus: Equatable, Sendable {
  case ready
  case requiresDownload
  case unsupported(reason: String)

  public init?(output: String) {
    let line = output
      .split(whereSeparator: \Character.isNewline)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let line, !line.isEmpty else { return nil }

    if line.hasPrefix("ready: Apple GPTK 4.0b2 ") {
      self = .ready
    } else if line.hasPrefix("requires-download: ") {
      self = .requiresDownload
    } else if line.hasPrefix("unsupported: ") {
      let reason = String(line.dropFirst("unsupported: ".count))
      guard !reason.isEmpty else { return nil }
      self = .unsupported(reason: reason)
    } else {
      return nil
    }
  }
}

/// Modelo de datos del onboarding del componente local Apple GPTK.
///
/// No abre URLs, busca archivos, ejecuta scripts ni descarga contenido. La capa de
/// presentación traduce sus acciones explícitas en interacción del usuario.
public struct AppleGPTKOnboarding: Equatable, Sendable {
  public struct Inputs: Equatable, Sendable {
    public let platformSupport: AppleGPTKPlatformSupport
    public let componentHealth: AppleGPTKComponentHealth
    public let dmgSelection: AppleGPTKDMGSelection
    public let licenseConfirmation: AppleGPTKLicenseConfirmation
    public let operation: AppleGPTKOnboardingOperation

    public init(
      platformSupport: AppleGPTKPlatformSupport,
      componentHealth: AppleGPTKComponentHealth,
      dmgSelection: AppleGPTKDMGSelection,
      licenseConfirmation: AppleGPTKLicenseConfirmation,
      operation: AppleGPTKOnboardingOperation
    ) {
      self.platformSupport = platformSupport
      self.componentHealth = componentHealth
      self.dmgSelection = dmgSelection
      self.licenseConfirmation = licenseConfirmation
      self.operation = operation
    }
  }

  public static let officialDownloadURL: URL = {
    guard let url = URL(
      string: "https://developer.apple.com/download/all/?q=Evaluation+environment+for+Windows+games"
    ) else {
      preconditionFailure("La URL oficial de Apple GPTK debe ser válida")
    }
    return url
  }()

  public let inputs: Inputs

  public init(inputs: Inputs) {
    self.inputs = inputs
  }

  public var officialDownloadURL: URL {
    Self.officialDownloadURL
  }

  public var state: AppleGPTKOnboardingState {
    if case .unsupported(let reason) = inputs.platformSupport {
      return .unsupported(reason: reason)
    }

    switch inputs.operation {
    case .verifying:
      return .verifying
    case .installing:
      return .installing
    case .failed(let message):
      return .failed(message: message)
    case .idle:
      break
    }

    switch inputs.componentHealth {
    case .ready:
      return .ready
    case .invalid(let reason):
      return .failed(message: reason)
    case .missing:
      break
    }

    switch inputs.dmgSelection {
    case .notDownloaded:
      return .requiresDownload
    case .availableForSelection:
      return .requiresSelection
    case .selected:
      return .requiresLicense
    }
  }

  public var allowedActions: [AppleGPTKOnboardingAction] {
    switch state {
    case .ready, .unsupported, .verifying, .installing:
      return []
    case .requiresDownload:
      return [.openOfficialDownload]
    case .requiresSelection:
      return [.selectDMG, .openOfficialDownload]
    case .requiresLicense:
      switch inputs.licenseConfirmation {
      case .notReviewed:
        return [.reviewLicense]
      case .confirmed:
        return [.install]
      }
    case .failed:
      return [.retry]
    }
  }
}

public struct AppleGPTKInspectionDescriptor: Codable, Equatable, Sendable {
  public let schema: Int
  public let version: String
  public let dmgSHA256: String
  public let licenseSHA256: String
  public let sourceDMG: String

  public init(
    schema: Int,
    version: String,
    dmgSHA256: String,
    licenseSHA256: String,
    sourceDMG: String
  ) {
    self.schema = schema
    self.version = version
    self.dmgSHA256 = dmgSHA256
    self.licenseSHA256 = licenseSHA256
    self.sourceDMG = sourceDMG
  }
}

/// Inspección no mutante del payload 3.0 que ya custodia Regression.
///
/// Es un contrato distinto del descriptor DMG: no contiene ni simula una identidad de imagen.
public struct AppleGPTKExistingComponentInspectionDescriptor: Codable, Equatable, Sendable {
  public static let sourceKind = "existing-protected-component"

  public let schema: Int
  public let version: String
  public let sourceKind: String
  public let catalogID: String
  public let payloadFingerprint: String
  public let licenseSHA256: String
  public let sourceComponent: String

  public init(
    schema: Int,
    version: String,
    sourceKind: String,
    catalogID: String,
    payloadFingerprint: String,
    licenseSHA256: String,
    sourceComponent: String
  ) {
    self.schema = schema
    self.version = version
    self.sourceKind = sourceKind
    self.catalogID = catalogID
    self.payloadFingerprint = payloadFingerprint
    self.licenseSHA256 = licenseSHA256
    self.sourceComponent = sourceComponent
  }
}

public enum AppleGPTKAuthorizationIssue: Equatable, Sendable {
  case unsupportedSchema
  case versionMismatch
  case dmgHashMismatch
  case licenseHashMismatch
  case sourceMismatch
  case sourceKindMismatch
  case catalogMismatch
  case payloadFingerprintMismatch
  case invalidAuthorization
  case invalidNonce
  case timestampInFuture
  case expired
}

public struct AppleGPTKExistingComponentAuthorizationToken: Codable, Equatable, Sendable {
  public static let validityInterval: TimeInterval = 600
  public static let authorizationValue = "user-confirmed-license"
  public static let confirmationValue = "ACEPTO LA LICENCIA DE APPLE GPTK 3.0"

  public let schema: Int
  public let version: String
  public let sourceKind: String
  public let catalogID: String
  public let payloadFingerprint: String
  public let licenseSHA256: String
  public let sourceComponent: String
  public let authorizedAt: Date
  public let nonce: String
  public let authorization: String
  public let confirmation: String

  public init(
    schema: Int,
    version: String,
    sourceKind: String,
    catalogID: String,
    payloadFingerprint: String,
    licenseSHA256: String,
    sourceComponent: String,
    authorizedAt: Date,
    nonce: String,
    authorization: String,
    confirmation: String
  ) {
    self.schema = schema
    self.version = version
    self.sourceKind = sourceKind
    self.catalogID = catalogID
    self.payloadFingerprint = payloadFingerprint
    self.licenseSHA256 = licenseSHA256
    self.sourceComponent = sourceComponent
    self.authorizedAt = authorizedAt
    self.nonce = nonce
    self.authorization = authorization
    self.confirmation = confirmation
  }

  public init(
    authorizing descriptor: AppleGPTKExistingComponentInspectionDescriptor,
    at date: Date,
    nonce: String
  ) {
    let isProtectedContract = Self.isProtectedContract(descriptor)
    self.init(
      schema: descriptor.schema,
      version: descriptor.version,
      sourceKind: descriptor.sourceKind,
      catalogID: descriptor.catalogID,
      payloadFingerprint: descriptor.payloadFingerprint,
      licenseSHA256: descriptor.licenseSHA256,
      sourceComponent: descriptor.sourceComponent,
      authorizedAt: date,
      nonce: nonce,
      authorization: isProtectedContract ? Self.authorizationValue : "",
      confirmation: isProtectedContract ? Self.confirmationValue : ""
    )
  }

  public func validation(
    against descriptor: AppleGPTKExistingComponentInspectionDescriptor,
    now: Date
  ) -> AppleGPTKAuthorizationValidation {
    guard schema == 1, descriptor.schema == 1 else {
      return .invalid(.unsupportedSchema)
    }
    guard version == descriptor.version, version == AppleGPTKComponentCatalog.protectedProfiles.version else {
      return .invalid(.versionMismatch)
    }
    guard sourceKind == descriptor.sourceKind,
      sourceKind == AppleGPTKExistingComponentInspectionDescriptor.sourceKind
    else {
      return .invalid(.sourceKindMismatch)
    }
    guard catalogID == descriptor.catalogID,
      catalogID == AppleGPTKComponentCatalog.protectedProfilesComponentID
    else {
      return .invalid(.catalogMismatch)
    }
    guard payloadFingerprint == descriptor.payloadFingerprint,
      payloadFingerprint == AppleGPTKComponentCatalog.protectedProfilesPayloadFingerprint
    else {
      return .invalid(.payloadFingerprintMismatch)
    }
    guard licenseSHA256 == descriptor.licenseSHA256 else {
      return .invalid(.licenseHashMismatch)
    }
    guard sourceComponent == descriptor.sourceComponent else {
      return .invalid(.sourceMismatch)
    }
    guard authorization == Self.authorizationValue,
      confirmation == Self.confirmationValue,
      Self.isProtectedContract(descriptor)
    else {
      return .invalid(.invalidAuthorization)
    }
    guard nonce.range(of: #"^[A-Za-z0-9_-]{32,128}$"#, options: .regularExpression) != nil else {
      return .invalid(.invalidNonce)
    }
    let age = now.timeIntervalSince(authorizedAt)
    guard age >= 0 else { return .invalid(.timestampInFuture) }
    guard age <= Self.validityInterval else { return .invalid(.expired) }
    return .valid
  }

  private static func isProtectedContract(
    _ descriptor: AppleGPTKExistingComponentInspectionDescriptor
  ) -> Bool {
    descriptor.schema == 1
      && descriptor.version == AppleGPTKComponentCatalog.protectedProfiles.version
      && descriptor.sourceKind == AppleGPTKExistingComponentInspectionDescriptor.sourceKind
      && descriptor.catalogID == AppleGPTKComponentCatalog.protectedProfilesComponentID
      && descriptor.payloadFingerprint
        == AppleGPTKComponentCatalog.protectedProfilesPayloadFingerprint
      && descriptor.licenseSHA256.range(
        of: #"^[0-9a-f]{64}$"#,
        options: .regularExpression
      ) != nil
      && descriptor.sourceComponent.hasPrefix("/")
  }

  private enum CodingKeys: String, CodingKey {
    case schema, version, sourceKind, catalogID, payloadFingerprint
    case licenseSHA256, sourceComponent, authorizedAt, nonce, authorization, confirmation
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schema = try values.decode(Int.self, forKey: .schema)
    version = try values.decode(String.self, forKey: .version)
    sourceKind = try values.decode(String.self, forKey: .sourceKind)
    catalogID = try values.decode(String.self, forKey: .catalogID)
    payloadFingerprint = try values.decode(String.self, forKey: .payloadFingerprint)
    licenseSHA256 = try values.decode(String.self, forKey: .licenseSHA256)
    sourceComponent = try values.decode(String.self, forKey: .sourceComponent)
    let timestamp = try values.decode(String.self, forKey: .authorizedAt)
    guard let parsedDate = Self.timestampFormatter.date(from: timestamp) else {
      throw DecodingError.dataCorruptedError(
        forKey: .authorizedAt,
        in: values,
        debugDescription: "authorizedAt debe usar ISO 8601 UTC"
      )
    }
    authorizedAt = parsedDate
    nonce = try values.decode(String.self, forKey: .nonce)
    authorization = try values.decode(String.self, forKey: .authorization)
    confirmation = try values.decode(String.self, forKey: .confirmation)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schema, forKey: .schema)
    try values.encode(version, forKey: .version)
    try values.encode(sourceKind, forKey: .sourceKind)
    try values.encode(catalogID, forKey: .catalogID)
    try values.encode(payloadFingerprint, forKey: .payloadFingerprint)
    try values.encode(licenseSHA256, forKey: .licenseSHA256)
    try values.encode(sourceComponent, forKey: .sourceComponent)
    try values.encode(Self.timestampFormatter.string(from: authorizedAt), forKey: .authorizedAt)
    try values.encode(nonce, forKey: .nonce)
    try values.encode(authorization, forKey: .authorization)
    try values.encode(confirmation, forKey: .confirmation)
  }

  private static var timestampFormatter: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }
}

public enum AppleGPTKAuthorizationValidation: Equatable, Sendable {
  case valid
  case invalid(AppleGPTKAuthorizationIssue)
}

public struct AppleGPTKAuthorizationToken: Codable, Equatable, Sendable {
  public static let validityInterval: TimeInterval = 600
  public static let authorizationValue = "user-confirmed-license"
  public static let confirmationValue = "ACEPTO LA LICENCIA DE APPLE GPTK 4.0b2"

  public let schema: Int
  public let version: String
  public let dmgSHA256: String
  public let licenseSHA256: String
  public let sourceDMG: String
  public let authorizedAt: Date
  public let nonce: String
  public let authorization: String
  public let confirmation: String

  public init(
    schema: Int,
    version: String,
    dmgSHA256: String,
    licenseSHA256: String,
    sourceDMG: String,
    authorizedAt: Date,
    nonce: String,
    authorization: String,
    confirmation: String
  ) {
    self.schema = schema
    self.version = version
    self.dmgSHA256 = dmgSHA256
    self.licenseSHA256 = licenseSHA256
    self.sourceDMG = sourceDMG
    self.authorizedAt = authorizedAt
    self.nonce = nonce
    self.authorization = authorization
    self.confirmation = confirmation
  }

  public init(
    authorizing descriptor: AppleGPTKInspectionDescriptor,
    at date: Date,
    nonce: String
  ) {
    self.init(
      schema: descriptor.schema,
      version: descriptor.version,
      dmgSHA256: descriptor.dmgSHA256,
      licenseSHA256: descriptor.licenseSHA256,
      sourceDMG: descriptor.sourceDMG,
      authorizedAt: date,
      nonce: nonce,
      authorization: Self.authorizationValue,
      confirmation: AppleGPTKComponentCatalog.component(version: descriptor.version)
        .flatMap {
          $0.supportsDMGOnboarding && $0.dmgSHA256 == descriptor.dmgSHA256
            ? $0.licenseConfirmation
            : nil
        } ?? ""
    )
  }

  public func validation(
    against descriptor: AppleGPTKInspectionDescriptor,
    now: Date
  ) -> AppleGPTKAuthorizationValidation {
    guard schema == 1, descriptor.schema == 1 else {
      return .invalid(.unsupportedSchema)
    }
    guard version == descriptor.version else {
      return .invalid(.versionMismatch)
    }
    guard dmgSHA256 == descriptor.dmgSHA256 else {
      return .invalid(.dmgHashMismatch)
    }
    guard licenseSHA256 == descriptor.licenseSHA256 else {
      return .invalid(.licenseHashMismatch)
    }
    guard sourceDMG == descriptor.sourceDMG else {
      return .invalid(.sourceMismatch)
    }
    guard authorization == Self.authorizationValue else {
      return .invalid(.invalidAuthorization)
    }
    guard
      let component = AppleGPTKComponentCatalog.component(version: version),
      component.supportsDMGOnboarding,
      component.dmgSHA256 == descriptor.dmgSHA256,
      confirmation == component.licenseConfirmation
    else {
      return .invalid(.invalidAuthorization)
    }
    guard nonce.range(of: #"^[A-Za-z0-9_-]{32,128}$"#, options: .regularExpression) != nil else {
      return .invalid(.invalidNonce)
    }

    let age = now.timeIntervalSince(authorizedAt)
    guard age >= 0 else {
      return .invalid(.timestampInFuture)
    }
    guard age <= Self.validityInterval else {
      return .invalid(.expired)
    }
    return .valid
  }

  private enum CodingKeys: String, CodingKey {
    case schema
    case version
    case dmgSHA256
    case licenseSHA256
    case sourceDMG
    case authorizedAt
    case nonce
    case authorization
    case confirmation
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schema = try values.decode(Int.self, forKey: .schema)
    version = try values.decode(String.self, forKey: .version)
    dmgSHA256 = try values.decode(String.self, forKey: .dmgSHA256)
    licenseSHA256 = try values.decode(String.self, forKey: .licenseSHA256)
    sourceDMG = try values.decode(String.self, forKey: .sourceDMG)
    let timestamp = try values.decode(String.self, forKey: .authorizedAt)
    guard let parsedDate = Self.timestampFormatter.date(from: timestamp) else {
      throw DecodingError.dataCorruptedError(
        forKey: .authorizedAt,
        in: values,
        debugDescription: "authorizedAt debe usar ISO 8601 UTC"
      )
    }
    authorizedAt = parsedDate
    nonce = try values.decode(String.self, forKey: .nonce)
    authorization = try values.decode(String.self, forKey: .authorization)
    confirmation = try values.decode(String.self, forKey: .confirmation)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schema, forKey: .schema)
    try values.encode(version, forKey: .version)
    try values.encode(dmgSHA256, forKey: .dmgSHA256)
    try values.encode(licenseSHA256, forKey: .licenseSHA256)
    try values.encode(sourceDMG, forKey: .sourceDMG)
    try values.encode(Self.timestampFormatter.string(from: authorizedAt), forKey: .authorizedAt)
    try values.encode(nonce, forKey: .nonce)
    try values.encode(authorization, forKey: .authorization)
    try values.encode(confirmation, forKey: .confirmation)
  }

  private static var timestampFormatter: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }
}
