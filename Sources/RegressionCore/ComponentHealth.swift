import CryptoKit
import Darwin
import Foundation

/// Variante exacta del artefacto cuyos hashes se compilaron en la aplicación.
///
/// Desarrollo y distribución pública no comparten necesariamente bytes: el empaquetado público
/// puede relocalizar, hacer strip y volver a firmar Mach-O antes de sellar su manifiesto final.
public enum ComponentArtifactVariant: Equatable, Sendable {
  case development
  case publicInstalled
  case unsupported(String)
}

public enum ComponentSourcePolicy: Equatable, Sendable {
  case bundled
  case userProvided
}

public struct ComponentIdentity: Equatable, Sendable {
  public let componentID: String
  public let componentVersion: String
  public let variant: ComponentArtifactVariant
  public let buildIdentifier: String

  public init(
    componentID: String,
    componentVersion: String,
    variant: ComponentArtifactVariant,
    buildIdentifier: String
  ) {
    self.componentID = componentID
    self.componentVersion = componentVersion
    self.variant = variant
    self.buildIdentifier = buildIdentifier
  }
}

/// Descriptor de confianza construido por código. No es `Codable` deliberadamente: una base de
/// datos, un juego o un manifiesto descargado no pueden convertir sus propios hashes en autoridad.
public struct TrustedComponentDescriptor: Equatable, Sendable {
  public let identity: ComponentIdentity
  public let payloadRootURL: URL
  public let manifestRelativePath: String
  public let expectedManifestSHA256: String
  public let sourcePolicy: ComponentSourcePolicy
  public let externalLinkURL: URL?

  public init(
    identity: ComponentIdentity,
    payloadRootURL: URL,
    manifestRelativePath: String,
    expectedManifestSHA256: String,
    sourcePolicy: ComponentSourcePolicy,
    externalLinkURL: URL? = nil
  ) {
    self.identity = identity
    self.payloadRootURL = payloadRootURL
    self.manifestRelativePath = manifestRelativePath
    self.expectedManifestSHA256 = expectedManifestSHA256.lowercased()
    self.sourcePolicy = sourcePolicy
    self.externalLinkURL = externalLinkURL
  }
}

/// Archivo individual cuya identidad criptográfica forma parte de un descriptor compilado.
///
/// El inicializador no es público deliberadamente: solo el catálogo de la aplicación puede
/// convertir una ruta y un hash en autoridad. Los consumidores pueden inspeccionar el contrato,
/// pero no construir uno desde datos descargados o persistidos.
public struct TrustedComponentFile: Equatable, Sendable {
  public let relativePath: String
  public let expectedSHA256: String

  init(relativePath: String, expectedSHA256: String) {
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256.lowercased()
  }
}

/// Descriptor compilado para un conjunto pequeño y explícito de archivos dentro de una raíz.
///
/// A diferencia de `TrustedComponentDescriptor`, este contrato no acepta un manifiesto situado
/// junto al payload. Tampoco inventaría el Wine root: solo abre las rutas enumeradas, sin seguir
/// enlaces y sin recorrer el resto del runtime.
public struct TrustedComponentFileSetDescriptor: Equatable, Sendable {
  public let identity: ComponentIdentity
  public let payloadRootURL: URL
  public let files: [TrustedComponentFile]
  let maximumFileBytes: Int64
  let maximumPayloadBytes: Int64
}

/// Catálogo mínimo de componentes que forman parte del código y del bundle firmado de Regression.
///
/// Este catálogo fija la identidad y el hash esperado, pero no convierte una ruta arbitraria en
/// una release auténtica. La aplicación debe resolver antes la variante desde su contexto de
/// distribución y superar sus gates externos de instalación canónica y firma. En particular, el
/// manifiesto observado nunca se usa para elegir `.development` o `.publicInstalled`: hacerlo
/// permitiría que un payload autoconsistente eligiera su propia autoridad.
public enum TrustedComponentCatalog {
  public static let windowsMediaComponentID = "windows-media-gstreamer"
  public static let windowsMediaComponentVersion = "1"
  public static let steamRuntimePrerequisitesComponentID = "steam-runtime-prerequisites"
  public static let steamRuntimePrerequisitesComponentVersion = "1"
  public static let supportedApplicationVersion = "1.11.0"
  public static let supportedBuildIdentifier = "37"

  private static let windowsMediaDevelopmentManifestSHA256 =
    "ac662661fb3384c6ad100066391cab209f9de60b2e129fb92e07365ee6fe9bb1"
  // Medido sobre el manifiesto regenerado después de relocalizar, firmar y sanear el primer
  // candidato público 1.11.0 (37). La aplicación se recompila tras fijarlo para que la autoridad
  // no proceda del propio payload descargado.
  private static let windowsMediaPublicManifestSHA256: String? = "da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3"
  private static let unsupportedManifestPlaceholder = String(repeating: "0", count: 64)
  private static let steamRuntimeMaximumFileBytes: Int64 = 128 * 1_024 * 1_024
  private static let steamRuntimeMaximumPayloadBytes: Int64 = 512 * 1_024 * 1_024

  private static let steamRuntimePrerequisiteFiles: [TrustedComponentFile] = [
    TrustedComponentFile(
      relativePath: "lib/wine/x86_64-windows/vcruntime140.dll",
      expectedSHA256: "f03a7c92ed8cda87fc0bf72a5af29962d26ca981b546b3ce0550fb57ca3ee7ff"
    ),
    TrustedComponentFile(
      relativePath: "lib/wine/x86_64-windows/msvcp140.dll",
      expectedSHA256: "2a53d2db7e7b760d2b1d7ecd46b05653e11850363a10b097303d3491aaa4e94a"
    ),
    TrustedComponentFile(
      relativePath: "lib/wine/x86_64-windows/ucrtbase.dll",
      expectedSHA256: "019e4bebf86cc4642fff63bc371223280ddfb0306ff379b04fe3f4dc2311ad22"
    ),
    TrustedComponentFile(
      relativePath: "lib/wine/x86_64-windows/vcruntime140_1.dll",
      expectedSHA256: "69e58956261ae1081a6429c3813b143689f29849ffb693eb4fee399f335e4608"
    ),
    TrustedComponentFile(
      relativePath: "lib/wine/i386-windows/vcruntime140.dll",
      expectedSHA256: "02037225c495c37747ae4cde08de6ff31119b850997799fa27237ca61bed7b35"
    ),
    TrustedComponentFile(
      relativePath: "lib/wine/i386-windows/msvcp140.dll",
      expectedSHA256: "2727caf41f37eec4141c891e42365e261cc909b01d0ae568b12b9bf2fdcffa85"
    ),
    TrustedComponentFile(
      relativePath: "lib/wine/i386-windows/ucrtbase.dll",
      expectedSHA256: "935fbefeb5462924e628df486ebfdad49b70a91154c9a8a57d9aa221fc91c119"
    ),
  ]

  /// Describe el payload LGPL de Windows Media incluido en Regression 1.11.0 (37).
  ///
  /// `applicationBundleURL` y `applicationSupportURL` se inyectan para que la app, los tests y
  /// un futuro verificador de staging inspeccionen exactamente el mismo contrato sin depender
  /// de `Bundle.main` ni de `$HOME`. La función solo construye datos; no ejecuta el instalador,
  /// no crea enlaces y no modifica el bundle.
  public static func windowsMediaDescriptor(
    applicationVersion: String,
    buildIdentifier: String,
    variant: ComponentArtifactVariant,
    applicationBundleURL: URL,
    applicationSupportURL: URL
  ) -> TrustedComponentDescriptor {
    let resolvedVariant: ComponentArtifactVariant
    let expectedManifestSHA256: String

    if applicationVersion != supportedApplicationVersion
      || buildIdentifier != supportedBuildIdentifier
    {
      resolvedVariant = .unsupported(
        "Regression \(applicationVersion) (\(buildIdentifier))"
      )
      expectedManifestSHA256 = unsupportedManifestPlaceholder
    } else {
      switch variant {
      case .development:
        resolvedVariant = .development
        expectedManifestSHA256 = windowsMediaDevelopmentManifestSHA256
      case .publicInstalled:
        if let publicManifestSHA256 = windowsMediaPublicManifestSHA256 {
          resolvedVariant = .publicInstalled
          expectedManifestSHA256 = publicManifestSHA256
        } else {
          resolvedVariant = .unsupported(
            "Regression 1.11.0 (37): manifiesto público pendiente de medir"
          )
          expectedManifestSHA256 = unsupportedManifestPlaceholder
        }
      case .unsupported(let name):
        resolvedVariant = .unsupported(name)
        expectedManifestSHA256 = unsupportedManifestPlaceholder
      }
    }

    let canonicalBundleURL = applicationBundleURL.standardizedFileURL
    let canonicalApplicationSupportURL = applicationSupportURL.standardizedFileURL
    return TrustedComponentDescriptor(
      identity: ComponentIdentity(
        componentID: windowsMediaComponentID,
        componentVersion: windowsMediaComponentVersion,
        variant: resolvedVariant,
        buildIdentifier: buildIdentifier
      ),
      payloadRootURL: canonicalBundleURL.appendingPathComponent(
        "Contents/SharedSupport/components/windows-media/1",
        isDirectory: true
      ),
      manifestRelativePath: "manifest.sha256",
      expectedManifestSHA256: expectedManifestSHA256,
      sourcePolicy: .bundled,
      externalLinkURL: canonicalApplicationSupportURL.appendingPathComponent(
        "Components/WindowsMedia/1",
        isDirectory: false
      )
    )
  }

  /// Describe los redistribuibles Windows incluidos en el Wine root de Regression 1.11.0 (37).
  ///
  /// Es una comprobación del conjunto sellado que la release ya debe contener, no un instalador:
  /// el resultado nunca descarga, copia, sustituye ni registra DLLs.
  public static func steamRuntimePrerequisitesDescriptor(
    applicationVersion: String,
    buildIdentifier: String,
    variant: ComponentArtifactVariant,
    wineRootURL: URL
  ) -> TrustedComponentFileSetDescriptor {
    let resolvedVariant: ComponentArtifactVariant
    if applicationVersion != supportedApplicationVersion
      || buildIdentifier != supportedBuildIdentifier
    {
      resolvedVariant = .unsupported(
        "Regression \(applicationVersion) (\(buildIdentifier))"
      )
    } else {
      resolvedVariant = variant
    }

    return TrustedComponentFileSetDescriptor(
      identity: ComponentIdentity(
        componentID: steamRuntimePrerequisitesComponentID,
        componentVersion: steamRuntimePrerequisitesComponentVersion,
        variant: resolvedVariant,
        buildIdentifier: buildIdentifier
      ),
      payloadRootURL: wineRootURL.standardizedFileURL,
      files: steamRuntimePrerequisiteFiles,
      maximumFileBytes: steamRuntimeMaximumFileBytes,
      maximumPayloadBytes: steamRuntimeMaximumPayloadBytes
    )
  }
}

public enum ComponentHealthStatus: String, Codable, Equatable, Sendable {
  case ready
  case missing
  case drifted
  case brokenLink
  case unsupportedVariant
  case repairable
  case requiresUserSource
}

/// Siguiente acción permitida. Es un plan de datos: evaluarlo nunca crea enlaces, descarga ni
/// sustituye archivos.
public enum ComponentRecoveryAction: Equatable, Sendable {
  case none
  case reinstallTrustedArtifact
  case createExternalLink(linkURL: URL, targetURL: URL)
  case restoreExternalLinkAfterBackup(linkURL: URL, targetURL: URL)
  case provideUserSource
  case installSupportedApplicationBuild
}

public enum ComponentHealthIssue: Equatable, Sendable {
  case unsupportedVariant(String)
  case invalidDescriptor
  case payloadMissing
  case payloadIsNotARegularDirectory
  case manifestMissing
  case manifestDigestMismatch
  case malformedManifest
  case unsafeManifestPath(String)
  case duplicateManifestPath(String)
  case payloadEntryMissing(String)
  case payloadEntryIsSymbolicLink(String)
  case payloadEntryIsNotRegularFile(String)
  case payloadEntryExceedsLimit(String)
  case payloadDigestMismatch(String)
  case unlistedPayloadEntry(String)
  case externalLinkMissing
  case externalLinkTargetMismatch
  case externalPathIsNotSymbolicLink
}

public struct ComponentHealthReport: Equatable, Sendable {
  public let identity: ComponentIdentity
  public let status: ComponentHealthStatus
  public let recovery: ComponentRecoveryAction
  public let issue: ComponentHealthIssue?

  public init(
    identity: ComponentIdentity,
    status: ComponentHealthStatus,
    recovery: ComponentRecoveryAction,
    issue: ComponentHealthIssue? = nil
  ) {
    self.identity = identity
    self.status = status
    self.recovery = recovery
    self.issue = issue
  }
}

/// Comprobación local, determinista y de solo lectura para componentes versionados.
public enum ComponentHealthService {
  private static let maximumManifestBytes = 4 * 1_024 * 1_024
  private static let maximumEntries = 4_096
  private static let maximumDepth = 32
  private static let maximumFileBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
  private static let maximumPayloadBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

  public static func evaluate(
    _ descriptor: TrustedComponentDescriptor,
    fileManager: FileManager = .default
  ) -> ComponentHealthReport {
    if case .unsupported(let name) = descriptor.identity.variant {
      return report(
        descriptor,
        status: .unsupportedVariant,
        recovery: .installSupportedApplicationBuild,
        issue: .unsupportedVariant(name)
      )
    }

    guard validDescriptor(descriptor) else {
      return driftReport(descriptor, issue: .invalidDescriptor)
    }
    guard let manifestRelativePath = safeRelativePath(descriptor.manifestRelativePath) else {
      return driftReport(descriptor, issue: .invalidDescriptor)
    }

    guard fileManager.fileExists(atPath: descriptor.payloadRootURL.path) else {
      switch descriptor.sourcePolicy {
      case .bundled:
        return report(
          descriptor,
          status: .missing,
          recovery: .reinstallTrustedArtifact,
          issue: .payloadMissing
        )
      case .userProvided:
        return report(
          descriptor,
          status: .requiresUserSource,
          recovery: .provideUserSource,
          issue: .payloadMissing
        )
      }
    }
    guard let payloadRoot = AnchoredDirectory.open(descriptor.payloadRootURL) else {
      return driftReport(descriptor, issue: .payloadIsNotARegularDirectory)
    }

    let manifestData: Data
    do {
      manifestData = try payloadRoot.readRegularFile(
        relativePath: manifestRelativePath,
        maximumBytes: Int64(maximumManifestBytes)
      )
    } catch {
      return driftReport(descriptor, issue: .manifestMissing)
    }
    guard sha256(manifestData) == descriptor.expectedManifestSHA256 else {
      return driftReport(descriptor, issue: .manifestDigestMismatch)
    }

    let entries: [ManifestEntry]
    do {
      entries = try parseManifest(
        manifestData,
        manifestRelativePath: manifestRelativePath
      )
    } catch let error as ManifestValidationError {
      return driftReport(descriptor, issue: error.issue)
    } catch {
      return driftReport(descriptor, issue: .malformedManifest)
    }

    var totalBytes: Int64 = 0
    var verifiedIdentities: [String: AnchoredFileIdentity] = [:]
    for entry in entries {
      let hashedFile: AnchoredFileDigest
      do {
        hashedFile = try payloadRoot.hashRegularFile(
          relativePath: entry.relativePath,
          maximumBytes: min(maximumFileBytes, maximumPayloadBytes - totalBytes)
        )
      } catch AnchoredFileError.symbolicLink {
        return driftReport(
          descriptor,
          issue: .payloadEntryIsSymbolicLink(entry.relativePath)
        )
      } catch {
        return driftReport(
          descriptor,
          issue: .payloadEntryMissing(entry.relativePath)
        )
      }
      totalBytes += hashedFile.byteCount
      verifiedIdentities[entry.relativePath] = hashedFile.identity
      guard hashedFile.sha256 == entry.sha256 else {
        return driftReport(
          descriptor,
          issue: .payloadDigestMismatch(entry.relativePath)
        )
      }
    }

    do {
      let listed = Set(verifiedIdentities.keys)
      let actual = try payloadRoot.payloadInventory(
        manifestRelativePath: manifestRelativePath,
        maximumEntries: maximumEntries,
        maximumDepth: maximumDepth
      )
      let actualPaths = Set(actual.keys)
      if let unexpected = actualPaths.subtracting(listed).sorted().first {
        return driftReport(descriptor, issue: .unlistedPayloadEntry(unexpected))
      }
      if let missing = listed.subtracting(actualPaths).sorted().first {
        return driftReport(descriptor, issue: .payloadEntryMissing(missing))
      }
      if let changed = listed.sorted().first(where: {
        actual[$0] != verifiedIdentities[$0]
      }) {
        return driftReport(descriptor, issue: .payloadDigestMismatch(changed))
      }
    } catch let error as ManifestValidationError {
      return driftReport(descriptor, issue: error.issue)
    } catch {
      return driftReport(descriptor, issue: .malformedManifest)
    }

    guard payloadRoot.isStillNamedBy(descriptor.payloadRootURL) else {
      return driftReport(descriptor, issue: .payloadIsNotARegularDirectory)
    }

    guard let externalLinkURL = descriptor.externalLinkURL else {
      return report(descriptor, status: .ready, recovery: .none)
    }
    guard
      let rawDestination = try? fileManager.destinationOfSymbolicLink(
        atPath: externalLinkURL.path
      )
    else {
      if fileManager.fileExists(atPath: externalLinkURL.path) {
        return report(
          descriptor,
          status: .brokenLink,
          recovery: .restoreExternalLinkAfterBackup(
            linkURL: externalLinkURL,
            targetURL: descriptor.payloadRootURL
          ),
          issue: .externalPathIsNotSymbolicLink
        )
      }
      return report(
        descriptor,
        status: .repairable,
        recovery: .createExternalLink(
          linkURL: externalLinkURL,
          targetURL: descriptor.payloadRootURL
        ),
        issue: .externalLinkMissing
      )
    }

    let destinationURL =
      rawDestination.hasPrefix("/")
      ? URL(fileURLWithPath: rawDestination)
      : externalLinkURL.deletingLastPathComponent().appendingPathComponent(rawDestination)
    guard destinationURL.standardizedFileURL == descriptor.payloadRootURL.standardizedFileURL else {
      return report(
        descriptor,
        status: .brokenLink,
        recovery: .restoreExternalLinkAfterBackup(
          linkURL: externalLinkURL,
          targetURL: descriptor.payloadRootURL
        ),
        issue: .externalLinkTargetMismatch
      )
    }
    guard payloadRoot.isStillNamedBy(descriptor.payloadRootURL) else {
      return driftReport(descriptor, issue: .payloadIsNotARegularDirectory)
    }
    return report(descriptor, status: .ready, recovery: .none)
  }

  /// Evalúa un conjunto pequeño sellado por código mediante aperturas relativas a una raíz fija.
  ///
  /// No inventaría el directorio ni recorre el Wine root. Cada archivo se abre con
  /// `O_NOFOLLOW`, se limita antes de leer y conserva la misma identidad durante el hash.
  public static func evaluate(
    _ descriptor: TrustedComponentFileSetDescriptor
  ) -> ComponentHealthReport {
    if case .unsupported(let name) = descriptor.identity.variant {
      return fileSetReport(
        descriptor,
        status: .unsupportedVariant,
        recovery: .installSupportedApplicationBuild,
        issue: .unsupportedVariant(name)
      )
    }

    guard validFileSetDescriptor(descriptor) else {
      return fileSetDriftReport(descriptor, issue: .invalidDescriptor)
    }

    guard let payloadRoot = AnchoredDirectory.open(descriptor.payloadRootURL) else {
      var metadata = stat()
      let existsWithoutFollowing = descriptor.payloadRootURL.path.withCString {
        Darwin.lstat($0, &metadata) == 0
      }
      if existsWithoutFollowing {
        return fileSetDriftReport(
          descriptor,
          issue: .payloadIsNotARegularDirectory
        )
      }
      return fileSetReport(
        descriptor,
        status: .missing,
        recovery: .reinstallTrustedArtifact,
        issue: .payloadMissing
      )
    }

    var totalBytes: Int64 = 0
    for file in descriptor.files {
      let remainingPayloadBytes = descriptor.maximumPayloadBytes - totalBytes
      guard remainingPayloadBytes >= 0 else {
        return fileSetDriftReport(
          descriptor,
          issue: .payloadEntryExceedsLimit(file.relativePath)
        )
      }

      let digest: AnchoredFileDigest
      do {
        digest = try payloadRoot.hashRegularFile(
          relativePath: file.relativePath,
          maximumBytes: min(descriptor.maximumFileBytes, remainingPayloadBytes)
        )
      } catch AnchoredFileError.symbolicLink {
        return fileSetDriftReport(
          descriptor,
          issue: .payloadEntryIsSymbolicLink(file.relativePath)
        )
      } catch AnchoredFileError.notRegularFile {
        return fileSetDriftReport(
          descriptor,
          issue: .payloadEntryIsNotRegularFile(file.relativePath)
        )
      } catch AnchoredFileError.notDirectory {
        return fileSetDriftReport(
          descriptor,
          issue: .payloadEntryIsNotRegularFile(file.relativePath)
        )
      } catch AnchoredFileError.exceedsBudget {
        return fileSetDriftReport(
          descriptor,
          issue: .payloadEntryExceedsLimit(file.relativePath)
        )
      } catch AnchoredFileError.changedDuringRead {
        return fileSetDriftReport(
          descriptor,
          issue: .payloadDigestMismatch(file.relativePath)
        )
      } catch {
        return fileSetReport(
          descriptor,
          status: .missing,
          recovery: .reinstallTrustedArtifact,
          issue: .payloadEntryMissing(file.relativePath)
        )
      }

      guard totalBytes <= descriptor.maximumPayloadBytes - digest.byteCount else {
        return fileSetDriftReport(
          descriptor,
          issue: .payloadEntryExceedsLimit(file.relativePath)
        )
      }
      totalBytes += digest.byteCount
      guard digest.sha256 == file.expectedSHA256 else {
        return fileSetDriftReport(
          descriptor,
          issue: .payloadDigestMismatch(file.relativePath)
        )
      }
    }

    guard payloadRoot.isStillNamedBy(descriptor.payloadRootURL) else {
      return fileSetDriftReport(
        descriptor,
        issue: .payloadIsNotARegularDirectory
      )
    }
    return fileSetReport(descriptor, status: .ready, recovery: .none)
  }

  private static func report(
    _ descriptor: TrustedComponentDescriptor,
    status: ComponentHealthStatus,
    recovery: ComponentRecoveryAction,
    issue: ComponentHealthIssue? = nil
  ) -> ComponentHealthReport {
    ComponentHealthReport(
      identity: descriptor.identity,
      status: status,
      recovery: recovery,
      issue: issue
    )
  }

  private static func fileSetReport(
    _ descriptor: TrustedComponentFileSetDescriptor,
    status: ComponentHealthStatus,
    recovery: ComponentRecoveryAction,
    issue: ComponentHealthIssue? = nil
  ) -> ComponentHealthReport {
    ComponentHealthReport(
      identity: descriptor.identity,
      status: status,
      recovery: recovery,
      issue: issue
    )
  }

  private static func fileSetDriftReport(
    _ descriptor: TrustedComponentFileSetDescriptor,
    issue: ComponentHealthIssue
  ) -> ComponentHealthReport {
    fileSetReport(
      descriptor,
      status: .drifted,
      recovery: .reinstallTrustedArtifact,
      issue: issue
    )
  }

  private static func driftReport(
    _ descriptor: TrustedComponentDescriptor,
    issue: ComponentHealthIssue
  ) -> ComponentHealthReport {
    report(
      descriptor,
      status: .drifted,
      recovery: descriptor.sourcePolicy == .bundled
        ? .reinstallTrustedArtifact
        : .provideUserSource,
      issue: issue
    )
  }

  private static func validDescriptor(_ descriptor: TrustedComponentDescriptor) -> Bool {
    let identity = descriptor.identity
    guard !identity.componentID.isEmpty,
      !identity.componentVersion.isEmpty,
      !identity.buildIdentifier.isEmpty,
      isSHA256(descriptor.expectedManifestSHA256),
      safeRelativePath(descriptor.manifestRelativePath) != nil
    else {
      return false
    }
    return true
  }

  private static func validFileSetDescriptor(
    _ descriptor: TrustedComponentFileSetDescriptor
  ) -> Bool {
    let identity = descriptor.identity
    guard !identity.componentID.isEmpty,
      !identity.componentVersion.isEmpty,
      !identity.buildIdentifier.isEmpty,
      !descriptor.files.isEmpty,
      descriptor.files.count <= 64,
      descriptor.maximumFileBytes > 0,
      descriptor.maximumPayloadBytes > 0
    else {
      return false
    }

    var seen: Set<String> = []
    for file in descriptor.files {
      guard safeRelativePath(file.relativePath) == file.relativePath,
        isSHA256(file.expectedSHA256),
        seen.insert(file.relativePath).inserted
      else {
        return false
      }
    }
    return true
  }

  private static func parseManifest(
    _ data: Data,
    manifestRelativePath: String
  ) throws -> [ManifestEntry] {
    guard !data.isEmpty,
      data.count <= maximumManifestBytes,
      data.last == 0x0a,
      let text = String(data: data, encoding: .utf8)
    else {
      throw ManifestValidationError(.malformedManifest)
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    guard !lines.isEmpty, lines.count <= maximumEntries else {
      throw ManifestValidationError(.malformedManifest)
    }

    let canonicalManifestPath = safeRelativePath(manifestRelativePath)
    var seen: Set<String> = []
    var result: [ManifestEntry] = []
    result.reserveCapacity(lines.count)
    for lineSlice in lines {
      let line = String(lineSlice)
      guard line.count >= 67 else {
        throw ManifestValidationError(.malformedManifest)
      }
      let hashEnd = line.index(line.startIndex, offsetBy: 64)
      let separatorEnd = line.index(hashEnd, offsetBy: 2)
      let digest = String(line[..<hashEnd]).lowercased()
      guard isSHA256(digest),
        line[hashEnd..<separatorEnd] == "  "
      else {
        throw ManifestValidationError(.malformedManifest)
      }
      let rawPath = String(line[separatorEnd...])
      guard let relativePath = safeRelativePath(rawPath),
        relativePath != canonicalManifestPath
      else {
        throw ManifestValidationError(.unsafeManifestPath(rawPath))
      }
      guard seen.insert(relativePath).inserted else {
        throw ManifestValidationError(.duplicateManifestPath(relativePath))
      }
      result.append(ManifestEntry(sha256: digest, relativePath: relativePath))
    }
    return result
  }

  private static func safeRelativePath(_ path: String) -> String? {
    guard !path.isEmpty,
      !path.hasPrefix("/"),
      !path.contains("\\"),
      !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    else {
      return nil
    }
    let trimmed = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      return nil
    }
    return components.joined(separator: "/")
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (0x30...0x39).contains(byte)
          || (0x41...0x46).contains(byte)
          || (0x61...0x66).contains(byte)
      }
  }
}

private enum AnchoredFileError: Error {
  case invalidPath
  case symbolicLink
  case notDirectory
  case notRegularFile
  case exceedsBudget
  case changedDuringRead
  case unreadable
}

private struct AnchoredFileDigest {
  let sha256: String
  let byteCount: Int64
  let identity: AnchoredFileIdentity
}

/// Descriptor de directorio que mantiene todas las aperturas debajo de la misma raíz ya validada.
///
/// `openat` con `O_NOFOLLOW` impide que una comprobación de ruta y la lectura posterior observen
/// objetos diferentes. Cada archivo se compara mediante `fstat` antes y después de leerlo para
/// rechazar cambios concurrentes de inode, tamaño, modo o tiempos de modificación.
private final class AnchoredDirectory {
  private let descriptor: Int32
  private let identity: AnchoredFileIdentity

  private init(descriptor: Int32, identity: AnchoredFileIdentity) {
    self.descriptor = descriptor
    self.identity = identity
  }

  deinit {
    Darwin.close(descriptor)
  }

  static func open(_ url: URL) -> AnchoredDirectory? {
    let fd = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard fd >= 0,
      let identity = fileIdentity(fd: fd),
      identity.isDirectory
    else {
      if fd >= 0 { Darwin.close(fd) }
      return nil
    }
    return AnchoredDirectory(descriptor: fd, identity: identity)
  }

  func isStillNamedBy(_ url: URL) -> Bool {
    guard let replacement = Self.open(url) else { return false }
    return replacement.identity == identity
  }

  func readRegularFile(relativePath: String, maximumBytes: Int64) throws -> Data {
    let fd = try openRegularFile(relativePath: relativePath)
    defer { Darwin.close(fd) }
    let before = try stableReadableIdentity(fd: fd, maximumBytes: maximumBytes)

    var result = Data()
    result.reserveCapacity(Int(before.size))
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw AnchoredFileError.unreadable
      }
      guard Int64(result.count) <= maximumBytes - Int64(count) else {
        throw AnchoredFileError.exceedsBudget
      }
      result.append(buffer, count: count)
    }
    try verifyStableIdentity(before, fd: fd, bytesRead: Int64(result.count))
    return result
  }

  func hashRegularFile(
    relativePath: String,
    maximumBytes: Int64
  ) throws -> AnchoredFileDigest {
    guard maximumBytes >= 0 else { throw AnchoredFileError.exceedsBudget }
    let fd = try openRegularFile(relativePath: relativePath)
    defer { Darwin.close(fd) }
    let before = try stableReadableIdentity(fd: fd, maximumBytes: maximumBytes)

    var hasher = SHA256()
    var bytesRead: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw AnchoredFileError.unreadable
      }
      guard bytesRead <= maximumBytes - Int64(count) else {
        throw AnchoredFileError.exceedsBudget
      }
      bytesRead += Int64(count)
      hasher.update(data: Data(buffer[0..<count]))
    }
    try verifyStableIdentity(before, fd: fd, bytesRead: bytesRead)
    return AnchoredFileDigest(
      sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
      byteCount: bytesRead,
      identity: before
    )
  }

  func payloadInventory(
    manifestRelativePath: String,
    maximumEntries: Int,
    maximumDepth: Int
  ) throws -> [String: AnchoredFileIdentity] {
    var result: [String: AnchoredFileIdentity] = [:]
    var budget = maximumEntries + 1
    try collectPayloadFiles(
      directoryFD: descriptor,
      relativeDirectory: "",
      depth: maximumDepth,
      budget: &budget,
      manifestRelativePath: manifestRelativePath,
      result: &result
    )
    return result
  }

  private func collectPayloadFiles(
    directoryFD: Int32,
    relativeDirectory: String,
    depth: Int,
    budget: inout Int,
    manifestRelativePath: String,
    result: inout [String: AnchoredFileIdentity]
  ) throws {
    guard depth > 0, budget > 0 else {
      throw ManifestValidationError(.malformedManifest)
    }
    let names = try directoryEntryNames(fd: directoryFD)
    for name in names.sorted() {
      budget -= 1
      guard budget >= 0 else {
        throw ManifestValidationError(.malformedManifest)
      }
      let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
      var metadata = stat()
      let status = name.withCString {
        Darwin.fstatat(directoryFD, $0, &metadata, AT_SYMLINK_NOFOLLOW)
      }
      guard status == 0 else {
        throw ManifestValidationError(.payloadEntryMissing(relativePath))
      }
      let kind = metadata.st_mode & S_IFMT
      if kind == S_IFLNK {
        throw ManifestValidationError(.payloadEntryIsSymbolicLink(relativePath))
      }
      if kind == S_IFDIR {
        let discoveredIdentity = AnchoredFileIdentity(metadata)
        let childFD = name.withCString {
          Darwin.openat(
            directoryFD,
            $0,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
          )
        }
        guard childFD >= 0 else {
          throw ManifestValidationError(.payloadEntryMissing(relativePath))
        }
        defer { Darwin.close(childFD) }
        guard let openedIdentity = Self.fileIdentity(fd: childFD),
          openedIdentity == discoveredIdentity
        else {
          throw ManifestValidationError(.payloadEntryMissing(relativePath))
        }
        try collectPayloadFiles(
          directoryFD: childFD,
          relativeDirectory: relativePath,
          depth: depth - 1,
          budget: &budget,
          manifestRelativePath: manifestRelativePath,
          result: &result
        )
        var currentMetadata = stat()
        let currentStatus = name.withCString {
          Darwin.fstatat(directoryFD, $0, &currentMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard currentStatus == 0,
          Self.fileIdentity(fd: childFD) == openedIdentity,
          AnchoredFileIdentity(currentMetadata) == openedIdentity
        else {
          throw ManifestValidationError(.payloadEntryMissing(relativePath))
        }
      } else if kind == S_IFREG {
        if relativePath != manifestRelativePath {
          let fileFD = name.withCString {
            Darwin.openat(
              directoryFD,
              $0,
              O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
          }
          guard fileFD >= 0 else {
            throw ManifestValidationError(.payloadEntryMissing(relativePath))
          }
          defer { Darwin.close(fileFD) }
          let discoveredIdentity = AnchoredFileIdentity(metadata)
          guard Self.fileIdentity(fd: fileFD) == discoveredIdentity else {
            throw ManifestValidationError(.payloadEntryMissing(relativePath))
          }
          result[relativePath] = discoveredIdentity
        }
      } else {
        throw ManifestValidationError(.payloadEntryMissing(relativePath))
      }
    }
  }

  private func openRegularFile(relativePath: String) throws -> Int32 {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw AnchoredFileError.invalidPath
    }

    var parentFD = descriptor
    var ownedParentFD: Int32?
    defer {
      if let ownedParentFD { Darwin.close(ownedParentFD) }
    }

    for component in components.dropLast() {
      let name = String(component)
      try rejectSymbolicLink(name: name, parentFD: parentFD)
      let nextFD = name.withCString {
        Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard nextFD >= 0 else { throw AnchoredFileError.notDirectory }
      if let previous = ownedParentFD { Darwin.close(previous) }
      ownedParentFD = nextFD
      parentFD = nextFD
    }

    let finalName = String(components.last!)
    try rejectSymbolicLink(name: finalName, parentFD: parentFD)
    let fd = finalName.withCString {
      Darwin.openat(parentFD, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    }
    guard fd >= 0 else {
      if errno == ELOOP { throw AnchoredFileError.symbolicLink }
      throw AnchoredFileError.unreadable
    }
    guard let identity = Self.fileIdentity(fd: fd), identity.isRegular else {
      Darwin.close(fd)
      throw AnchoredFileError.notRegularFile
    }
    return fd
  }

  private func rejectSymbolicLink(name: String, parentFD: Int32) throws {
    var metadata = stat()
    let status = name.withCString {
      Darwin.fstatat(parentFD, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard status == 0 else { throw AnchoredFileError.unreadable }
    if metadata.st_mode & S_IFMT == S_IFLNK {
      throw AnchoredFileError.symbolicLink
    }
  }

  private func stableReadableIdentity(
    fd: Int32,
    maximumBytes: Int64
  ) throws -> AnchoredFileIdentity {
    guard let identity = Self.fileIdentity(fd: fd), identity.isRegular else {
      throw AnchoredFileError.notRegularFile
    }
    guard identity.size >= 0, identity.size <= maximumBytes else {
      throw AnchoredFileError.exceedsBudget
    }
    return identity
  }

  private func verifyStableIdentity(
    _ before: AnchoredFileIdentity,
    fd: Int32,
    bytesRead: Int64
  ) throws {
    guard let after = Self.fileIdentity(fd: fd),
      before == after,
      bytesRead == before.size
    else {
      throw AnchoredFileError.changedDuringRead
    }
  }

  private func directoryEntryNames(fd: Int32) throws -> [String] {
    let duplicate = Darwin.dup(fd)
    guard duplicate >= 0 else { throw AnchoredFileError.unreadable }
    _ = Darwin.fcntl(duplicate, F_SETFD, FD_CLOEXEC)
    guard let directory = Darwin.fdopendir(duplicate) else {
      Darwin.close(duplicate)
      throw AnchoredFileError.unreadable
    }
    defer { Darwin.closedir(directory) }

    var names: [String] = []
    errno = 0
    while let entry = Darwin.readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(validatingCString: $0)
        }
      }
      guard let name else { throw AnchoredFileError.unreadable }
      if name != "." && name != ".." { names.append(name) }
      errno = 0
    }
    guard errno == 0 else { throw AnchoredFileError.unreadable }
    return names
  }

  private static func fileIdentity(fd: Int32) -> AnchoredFileIdentity? {
    var metadata = stat()
    guard Darwin.fstat(fd, &metadata) == 0 else { return nil }
    return AnchoredFileIdentity(metadata)
  }
}

private struct AnchoredFileIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
  let mode: mode_t
  let size: Int64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let changeSeconds: Int64
  let changeNanoseconds: Int64

  init(_ metadata: stat) {
    device = metadata.st_dev
    inode = metadata.st_ino
    mode = metadata.st_mode
    size = metadata.st_size
    modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
    modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
    changeSeconds = Int64(metadata.st_ctimespec.tv_sec)
    changeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
  }

  var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
  var isRegular: Bool { mode & S_IFMT == S_IFREG }

}

private struct ManifestEntry: Equatable {
  let sha256: String
  let relativePath: String
}

private struct ManifestValidationError: Error {
  let issue: ComponentHealthIssue

  init(_ issue: ComponentHealthIssue) {
    self.issue = issue
  }
}
