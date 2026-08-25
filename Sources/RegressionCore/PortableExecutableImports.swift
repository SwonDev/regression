import Foundation

/// Lectura acotada de las tablas de importación de un PE de Windows.
///
/// Existe para poder decidir por **evidencia del propio binario** qué API gráfica usa un juego,
/// en vez de inferirlo del nombre del ejecutable, del App ID o de una lista mantenida a mano.
///
/// La distinción entre importación estática y *delay-load* es la que importa aquí: Unreal no
/// enlaza `d3d12.dll` de forma estática —el juego arrancaría en máquinas sin D3D12—, lo declara
/// como delay-load y decide en tiempo de ejecución. Buscar la cadena `d3d12.dll` por el fichero
/// entero encuentra esa referencia, pero también encontraría cualquier dato incrustado que la
/// contenga; leer el directorio de delay-load la acredita.
///
/// Todo está acotado: el fichero no se mapea entero, las secciones y los descriptores tienen
/// tope, y un enlace simbólico se rechaza.
public struct PortableExecutableImports: Equatable, Sendable {
    /// Módulos enlazados de forma estática: el cargador los resuelve antes de ejecutar nada.
    public let linked: [String]
    /// Módulos declarados como *delay-load*: se resuelven en la primera llamada, si llega.
    public let delayed: [String]

    public init(linked: [String], delayed: [String]) {
        self.linked = linked
        self.delayed = delayed
    }

    public func imports(_ module: String) -> Bool {
        let needle = module.lowercased()
        return linked.contains(needle) || delayed.contains(needle)
    }

    public func delayLoads(_ module: String) -> Bool {
        delayed.contains(module.lowercased())
    }
}

/// Arquitectura declarada en la cabecera COFF. Solo se distinguen las dos que este runtime
/// ejecuta; cualquier otra se reporta como desconocida en vez de adivinarse.
public enum PortableExecutableMachine: Equatable, Sendable {
    case i386
    case amd64
    case other(UInt16)
}

public enum PortableExecutableReader {
    private static let maximumSections = 96
    private static let maximumDescriptors = 4_096
    private static let maximumNameBytes = 64
    private static let maximumHeaderBytes = 64 * 1024

    /// Arquitectura del PE, leyendo solo la cabecera COFF.
    ///
    /// Hace falta porque una redirección de imagen **no puede cruzar arquitecturas**: sustituir
    /// el ejecutable de un proceso de 32 bits por uno de 64 hace que Windows —y Wine— rechacen la
    /// creación del proceso con `ERROR_NOT_SUPPORTED`, y desde fuera se ve como «el juego no
    /// arranca». Se comprueba antes de proponer la ruta, no después de romperla.
    public static func machine(at url: URL) throws -> PortableExecutableMachine? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              values.isRegularFile == true else { return nil }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let dos = try handle.read(upToCount: 0x40), dos.count == 0x40,
              dos[0] == 0x4D, dos[1] == 0x5A else { return nil }
        let peOffset = Int(read32(dos, at: 0x3C))
        guard peOffset > 0, peOffset < maximumHeaderBytes else { return nil }

        try handle.seek(toOffset: UInt64(peOffset))
        guard let coff = try handle.read(upToCount: 6), coff.count == 6,
              coff[0] == 0x50, coff[1] == 0x45, coff[2] == 0, coff[3] == 0 else { return nil }
        switch read16(coff, at: 4) {
        case 0x014c: return .i386
        case 0x8664: return .amd64
        case let value: return .other(value)
        }
    }

    /// Devuelve `nil` cuando el fichero no es un PE legible. La ausencia de tabla no es un error:
    /// un ejecutable puede no importar nada de forma estática.
    public static func imports(at url: URL) throws -> PortableExecutableImports? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              values.isRegularFile == true else { return nil }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let dos = try handle.read(upToCount: 0x40), dos.count == 0x40,
              dos[0] == 0x4D, dos[1] == 0x5A else { return nil }              // "MZ"
        let peOffset = Int(read32(dos, at: 0x3C))
        guard peOffset > 0, peOffset < maximumHeaderBytes else { return nil }

        try handle.seek(toOffset: UInt64(peOffset))
        guard let coff = try handle.read(upToCount: 24), coff.count == 24,
              coff[0] == 0x50, coff[1] == 0x45, coff[2] == 0, coff[3] == 0 else { return nil } // "PE\0\0"
        let sectionCount = Int(read16(coff, at: 6))
        let optionalSize = Int(read16(coff, at: 20))
        guard sectionCount > 0, sectionCount <= maximumSections,
              optionalSize > 0, optionalSize <= maximumHeaderBytes else { return nil }

        guard let optional = try handle.read(upToCount: optionalSize),
              optional.count == optionalSize else { return nil }
        let magic = read16(optional, at: 0)
        // 0x20b = PE32+ (64 bits); 0x10b = PE32. Cambia dónde empieza el directorio de datos.
        let directoryOffset: Int
        switch magic {
        case 0x20b: directoryOffset = 112
        case 0x10b: directoryOffset = 96
        default: return nil
        }
        guard optional.count >= directoryOffset + 16 * 8 else { return nil }
        let importRVA = read32(optional, at: directoryOffset + 8)
        let delayRVA = read32(optional, at: directoryOffset + 13 * 8)

        var sections: [(virtualAddress: UInt32, virtualSize: UInt32, rawPointer: UInt32, rawSize: UInt32)] = []
        for _ in 0..<sectionCount {
            guard let raw = try handle.read(upToCount: 40), raw.count == 40 else { return nil }
            sections.append((
                virtualAddress: read32(raw, at: 12),
                virtualSize: read32(raw, at: 8),
                rawPointer: read32(raw, at: 20),
                rawSize: read32(raw, at: 16)
            ))
        }

        let linked = try names(
            handle: handle,
            sections: sections,
            directoryRVA: importRVA,
            descriptorSize: 20,
            nameFieldOffset: 12
        )
        let delayed = try names(
            handle: handle,
            sections: sections,
            directoryRVA: delayRVA,
            descriptorSize: 32,
            nameFieldOffset: 4
        )
        return PortableExecutableImports(linked: linked, delayed: delayed)
    }

    private static func names(
        handle: FileHandle,
        sections: [(virtualAddress: UInt32, virtualSize: UInt32, rawPointer: UInt32, rawSize: UInt32)],
        directoryRVA: UInt32,
        descriptorSize: Int,
        nameFieldOffset: Int
    ) throws -> [String] {
        guard directoryRVA != 0,
              let base = fileOffset(of: directoryRVA, in: sections) else { return [] }

        var result: [String] = []
        for index in 0..<maximumDescriptors {
            let offset = base + UInt64(index * descriptorSize)
            try handle.seek(toOffset: offset)
            guard let descriptor = try handle.read(upToCount: descriptorSize),
                  descriptor.count == descriptorSize else { break }
            // Un descriptor a cero cierra la tabla.
            if descriptor.allSatisfy({ $0 == 0 }) { break }
            let nameRVA = read32(descriptor, at: nameFieldOffset)
            if nameRVA == 0 { break }
            guard let nameOffset = fileOffset(of: nameRVA, in: sections) else { continue }
            try handle.seek(toOffset: nameOffset)
            guard let raw = try handle.read(upToCount: maximumNameBytes), !raw.isEmpty else { continue }
            let bytes = Array(raw.prefix(while: { $0 != 0 }))
            guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { continue }
            result.append(String(decoding: bytes, as: UTF8.self).lowercased())
        }
        return result
    }

    private static func fileOffset(
        of rva: UInt32,
        in sections: [(virtualAddress: UInt32, virtualSize: UInt32, rawPointer: UInt32, rawSize: UInt32)]
    ) -> UInt64? {
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            guard span > 0,
                  rva >= section.virtualAddress,
                  rva < section.virtualAddress &+ span else { continue }
            return UInt64(section.rawPointer) + UInt64(rva - section.virtualAddress)
        }
        return nil
    }

    private static func read16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        guard base + 1 < data.endIndex else { return 0 }
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func read32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        guard base + 3 < data.endIndex else { return 0 }
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
