import Foundation

/// Estado de un requisito heredado detectado durante el inventario de un juego.
///
/// Estos estados no son acciones. En particular, `installableMissing` no autoriza descargar,
/// ejecutar ni reutilizar el redistribuible que el juego incluya: solo comunica que Regression
/// conoce una fuente oficial, pero todavía no tiene un payload sellado y una transacción aprobada.
public enum LegacyRuntimeComponentState: String, Codable, CaseIterable, Sendable {
    case observed
    case required
    case unsupported
    case installableMissing
    case ready

    public var blocksLaunch: Bool { self != .ready }
}

public enum LegacyRuntimeComponentHashRequirement: String, Codable, Equatable, Sendable {
    case sha256RequiredBeforeInstallation
}

public enum LegacyRuntimeComponentSource: String, Codable, Equatable, Sendable {
    case officialPublisher
}

/// Contrato declarativo compilado para una familia de componentes heredados.
///
/// `hashRequirement` exige fijar un SHA-256 antes de que una futura vertical transaccional pueda
/// siquiera proponer una instalación. No existe payload, ejecutor ni comando en este tipo.
public struct LegacyRuntimeComponentDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: String { componentID }
    public let componentID: String
    public let componentVersion: String
    public let displayName: String
    public let source: LegacyRuntimeComponentSource
    public let license: String
    public let hashRequirement: LegacyRuntimeComponentHashRequirement
    public let unavailableState: LegacyRuntimeComponentState
    public let explanation: String

    public init(
        componentID: String,
        componentVersion: String,
        displayName: String,
        source: LegacyRuntimeComponentSource,
        license: String,
        hashRequirement: LegacyRuntimeComponentHashRequirement,
        unavailableState: LegacyRuntimeComponentState,
        explanation: String
    ) {
        self.componentID = componentID
        self.componentVersion = componentVersion
        self.displayName = displayName
        self.source = source
        self.license = license
        self.hashRequirement = hashRequirement
        self.unavailableState = unavailableState
        self.explanation = explanation
    }
}

public struct LegacyRuntimeComponentResolution: Codable, Equatable, Sendable {
    public let componentID: String
    public let componentVersion: String
    public let state: LegacyRuntimeComponentState
    public let explanation: String

    public init(
        componentID: String,
        componentVersion: String,
        state: LegacyRuntimeComponentState,
        explanation: String
    ) {
        self.componentID = componentID
        self.componentVersion = componentVersion
        self.state = state
        self.explanation = explanation
    }

    public var isReady: Bool { state == .ready }
}

/// Catálogo cerrado de requisitos legacy.
///
/// No existe actualmente un descriptor de payload sellado para estos componentes. Por eso este
/// catálogo no puede producir `ready`: una futura vertical tendrá que aportar su propio contrato
/// de archivos, hash y rollback, en vez de confiar en un `ComponentHealthReport` construido por
/// un consumidor.
public enum LegacyRuntimeComponentCatalog {
    private static let microsoftLicense = "Microsoft Software License Terms; user review required"

    /// Todos los descriptores permanecen sin payload hasta que exista una autoridad transaccional
    /// independiente que fije hash, licencia aceptada y rollback.
    public static let descriptors: [LegacyRuntimeComponentDescriptor] = [
        descriptor(
            id: "directx-june-2010-runtime",
            version: "June 2010",
            name: "Microsoft DirectX End-User Runtimes (June 2010)",
            source: .officialPublisher,
            explanation: "Se detectó DirectX June 2010. Regression no ejecuta DXSETUP del juego; falta un payload oficial sellado."
        ),
        LegacyRuntimeComponentDescriptor(
            componentID: "directx-runtime-observed",
            componentVersion: "unknown",
            displayName: "Microsoft DirectX Runtime",
            source: .officialPublisher,
            license: microsoftLicense,
            hashRequirement: .sha256RequiredBeforeInstallation,
            unavailableState: .required,
            explanation: "Se detectó DXSETUP con DSETUP, pero no un marcador específico de DirectX June 2010. Regression no atribuye una versión."
        ),
        descriptor(
            id: "microsoft-xna-framework-3.1",
            version: "3.1",
            name: "Microsoft XNA Framework Redistributable 3.1",
            source: .officialPublisher,
            explanation: "Se detectó XNA Framework 3.1. El redistribuible empaquetado solo es evidencia; falta un payload oficial sellado."
        ),
        descriptor(
            id: "microsoft-xna-framework-4.0",
            version: "4.0",
            name: "Microsoft XNA Framework Redistributable 4.0",
            source: .officialPublisher,
            explanation: "Se detectó XNA Framework 4.0. Regression no usa Winetricks ni ejecuta instaladores del juego."
        ),
        descriptor(
            id: "microsoft-dotnet-framework-4.0",
            version: "4.0",
            name: "Microsoft .NET Framework 4.0",
            source: .officialPublisher,
            explanation: "Se detectó .NET Framework 4.0. Falta una autoridad de componente sellado antes de instalarlo."
        ),
        descriptor(
            id: "microsoft-dotnet-framework-4.5",
            version: "4.5",
            name: "Microsoft .NET Framework 4.5",
            source: .officialPublisher,
            explanation: "Se detectó .NET Framework 4.5. La detección no autoriza ejecutar el instalador empaquetado."
        ),
        descriptor(
            id: "microsoft-dotnet-framework-4.8",
            version: "4.8",
            name: "Microsoft .NET Framework 4.8",
            source: .officialPublisher,
            explanation: "Se detectó .NET Framework 4.8. Falta payload oficial sellado y una transacción con rollback."
        ),
        descriptor(
            id: "microsoft-vc-runtime-arm64",
            version: "latest-supported",
            name: "Microsoft Visual C++ Redistributable ARM64",
            source: .officialPublisher,
            unavailableState: .unsupported,
            explanation: "El redistribuible VC++ ARM64 no es compatible con el runtime Wine x86-64 de Regression."
        ),
        LegacyRuntimeComponentDescriptor(
            componentID: "microsoft-xna-framework-unknown",
            componentVersion: "unknown",
            displayName: "Microsoft XNA Framework",
            source: .officialPublisher,
            license: microsoftLicense,
            hashRequirement: .sha256RequiredBeforeInstallation,
            unavailableState: .required,
            explanation: "Se detectó XNA, pero no una versión verificable. El juego queda bloqueado hasta identificar la versión exacta."
        ),
        LegacyRuntimeComponentDescriptor(
            componentID: "microsoft-dotnet-framework-observed",
            componentVersion: "unknown",
            displayName: "Microsoft .NET Framework",
            source: .officialPublisher,
            license: microsoftLicense,
            hashRequirement: .sha256RequiredBeforeInstallation,
            unavailableState: .observed,
            explanation: "Se observó un redistribuible .NET sin versión verificable. Regression no infiere una versión ni ejecuta ese archivo."
        )
    ]

    public static func descriptor(
        forRequirementIdentifier identifier: String
    ) -> LegacyRuntimeComponentDescriptor? {
        descriptors.first { $0.componentID == identifier }
    }

    public static func descriptor(componentID: String) -> LegacyRuntimeComponentDescriptor? {
        descriptors.first { $0.componentID == componentID }
    }

    public static func resolution(
        forRequirementIdentifier identifier: String
    ) -> LegacyRuntimeComponentResolution? {
        guard let descriptor = descriptor(forRequirementIdentifier: identifier) else { return nil }
        return LegacyRuntimeComponentResolution(
            componentID: descriptor.componentID,
            componentVersion: descriptor.componentVersion,
            state: descriptor.unavailableState,
            explanation: descriptor.explanation
        )
    }

    private static func descriptor(
        id: String,
        version: String,
        name: String,
        source: LegacyRuntimeComponentSource,
        unavailableState: LegacyRuntimeComponentState = .installableMissing,
        explanation: String
    ) -> LegacyRuntimeComponentDescriptor {
        LegacyRuntimeComponentDescriptor(
            componentID: id,
            componentVersion: version,
            displayName: name,
            source: source,
            license: microsoftLicense,
            hashRequirement: .sha256RequiredBeforeInstallation,
            unavailableState: unavailableState,
            explanation: explanation
        )
    }
}
