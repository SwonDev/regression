import Foundation

/// Inventario revisado manualmente. Es informativo y no descarga ni activa componentes.
public enum RuntimeTechnologyCatalog {
    public static let revision = "2026-07-28.1"
    public static let checkedAt = Date(timeIntervalSince1970: 1_785_196_800)

    public static let all: [RuntimeTechnology] = [
        RuntimeTechnology(
            id: "apple-rosetta",
            displayName: "Rosetta",
            category: .cpuTranslation,
            officialURL: URL(string: "https://developer.apple.com/documentation/Apple-Silicon/about-the-rosetta-translation-environment")!,
            distributionPolicy: .systemProvided,
            updatePolicy: .systemManaged,
            stableVersion: "gestionada por macOS",
            latestKnownVersion: "gestionada por macOS",
            checkedAt: checkedAt,
            notes: "Apple mantiene Rosetta de propósito general hasta macOS 27; Regression debe desarrollar una vía sin Rosetta antes de macOS 28."
        ),
        RuntimeTechnology(
            id: "wine",
            displayName: "Wine",
            category: .windowsRuntime,
            officialURL: URL(string: "https://www.winehq.org/")!,
            releaseURL: URL(string: "https://www.winehq.org/news/2026011301")!,
            distributionPolicy: .openSource,
            updatePolicy: .candidateOnly,
            stableVersion: "11.0",
            latestKnownVersion: "11.0",
            checkedAt: checkedAt,
            notes: "El build estable conserva el prefijo horneado de Regression. Otros builds se prueban por juego y de forma autocontenida."
        ),
        RuntimeTechnology(
            id: "apple-gptk",
            displayName: "Apple Game Porting Toolkit / D3DMetal",
            category: .graphicsTranslation,
            officialURL: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!,
            distributionPolicy: .localUserProvided,
            updatePolicy: .candidateOnly,
            stableVersion: "3.0",
            latestKnownVersion: "4.0",
            checkedAt: checkedAt,
            notes: "GPTK 4 añade Metal 4 y herramientas nuevas. Sus binarios son locales del usuario y nunca se redistribuyen."
        ),
        RuntimeTechnology(
            id: "dxmt",
            displayName: "DXMT",
            category: .graphicsTranslation,
            officialURL: URL(string: "https://github.com/3Shain/dxmt")!,
            releaseURL: URL(string: "https://github.com/3Shain/dxmt/releases/tag/v0.80")!,
            distributionPolicy: .openSource,
            updatePolicy: .candidateOnly,
            stableVersion: "0.72 + parche cross-process de Regression",
            latestKnownVersion: "0.80",
            checkedAt: checkedAt,
            notes: "El PIN 0.72 protege Steam y Palworld. 0.80 solo puede entrar como candidato aislado hasta superar su matriz."
        ),
        RuntimeTechnology(
            id: "dxvk",
            displayName: "DXVK",
            category: .graphicsTranslation,
            officialURL: URL(string: "https://github.com/doitsujin/dxvk")!,
            releaseURL: URL(string: "https://github.com/doitsujin/dxvk/releases/tag/v3.0.2")!,
            distributionPolicy: .openSource,
            updatePolicy: .candidateOnly,
            stableVersion: "1.10.3 (D3D9)",
            latestKnownVersion: "3.0.2",
            checkedAt: checkedAt,
            notes: "El D3D9 estable permanece fijado; las ramas modernas se comparan por juego con un Vulkan compatible."
        ),
        RuntimeTechnology(
            id: "moltenvk",
            displayName: "MoltenVK",
            category: .vulkanRuntime,
            officialURL: URL(string: "https://github.com/KhronosGroup/MoltenVK")!,
            releaseURL: URL(string: "https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2")!,
            distributionPolicy: .openSource,
            updatePolicy: .candidateOnly,
            stableVersion: "1.2.10",
            latestKnownVersion: "1.4.2",
            checkedAt: checkedAt,
            notes: "Una actualización de MoltenVK se evalúa junto al DXVK/vkd3d exacto que la consume, nunca como sustitución global aislada."
        ),
        RuntimeTechnology(
            id: "vkd3d",
            displayName: "Wine vkd3d",
            category: .graphicsTranslation,
            officialURL: URL(string: "https://gitlab.winehq.org/wine/vkd3d")!,
            distributionPolicy: .openSource,
            updatePolicy: .pinnedStable,
            stableVersion: "1.18",
            latestKnownVersion: "1.18",
            checkedAt: checkedAt,
            notes: "Baseline D3D12 actual del árbol propio. Cualquier sustitución debe resolver primero la pareja dxgi documentada."
        ),
        RuntimeTechnology(
            id: "vkd3d-proton",
            displayName: "vkd3d-proton",
            category: .graphicsTranslation,
            officialURL: URL(string: "https://github.com/HansKristian-Work/vkd3d-proton")!,
            releaseURL: URL(string: "https://github.com/HansKristian-Work/vkd3d-proton/releases/tag/v3.0.1")!,
            distributionPolicy: .openSource,
            updatePolicy: .candidateOnly,
            stableVersion: nil,
            latestKnownVersion: "3.0.1",
            checkedAt: checkedAt,
            notes: "Línea de investigación independiente; no se considera una actualización directa de Wine vkd3d."
        ),
        RuntimeTechnology(
            id: "crossover",
            displayName: "CrossOver",
            category: .referenceRuntime,
            officialURL: URL(string: "https://www.codeweavers.com/crossover")!,
            distributionPolicy: .licensedReference,
            updatePolicy: .referenceOnly,
            stableVersion: "26.3.0 (referencia observada)",
            latestKnownVersion: nil,
            checkedAt: checkedAt,
            notes: "Referencia temporal mediante su CLI oficial. El motor propio no enlaza ni copia componentes propietarios."
        )
    ]
}
