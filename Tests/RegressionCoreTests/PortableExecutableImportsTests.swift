import Foundation
import XCTest
@testable import RegressionCore

/// Construye un PE64 mínimo pero real: cabecera DOS, firma PE, cabecera opcional PE32+, una
/// sección y las dos tablas de importación. Sirve para probar el lector sin depender de binarios
/// de juegos, que no se pueden versionar.
enum MinimalPortableExecutable {
    static func data(linked: [String], delayed: [String], magic: UInt16 = 0x20b) -> Data {
        let sectionRVA: UInt32 = 0x1000
        let headerSize = 0x400
        var section = Data()

        // Las cadenas y los descriptores viven en la misma sección; se calculan sus RVA.
        func appendNames(_ names: [String]) -> [UInt32] {
            var rvas: [UInt32] = []
            for name in names {
                rvas.append(sectionRVA + UInt32(section.count))
                section.append(contentsOf: Array(name.utf8))
                section.append(0)
            }
            return rvas
        }
        let linkedNameRVAs = appendNames(linked)
        let delayedNameRVAs = appendNames(delayed)
        while section.count % 8 != 0 { section.append(0) }

        let importRVA = sectionRVA + UInt32(section.count)
        for rva in linkedNameRVAs {
            var descriptor = Data(count: 20)
            descriptor.replaceSubrange(12..<16, with: le32(rva))
            section.append(descriptor)
        }
        section.append(Data(count: 20))                       // descriptor nulo: cierra la tabla

        let delayRVA = sectionRVA + UInt32(section.count)
        for rva in delayedNameRVAs {
            var descriptor = Data(count: 32)
            descriptor.replaceSubrange(4..<8, with: le32(rva))
            section.append(descriptor)
        }
        section.append(Data(count: 32))

        let optionalSize = (magic == 0x20b ? 112 : 96) + 16 * 8
        var file = Data(count: headerSize)
        file.replaceSubrange(0..<2, with: Data("MZ".utf8))
        let peOffset = 0x80
        file.replaceSubrange(0x3C..<0x40, with: le32(UInt32(peOffset)))
        file.replaceSubrange(peOffset..<(peOffset + 4), with: Data("PE\0\0".utf8))
        file.replaceSubrange((peOffset + 6)..<(peOffset + 8), with: le16(1))               // 1 sección
        file.replaceSubrange((peOffset + 20)..<(peOffset + 22), with: le16(UInt16(optionalSize)))

        let optionalOffset = peOffset + 24
        file.replaceSubrange(optionalOffset..<(optionalOffset + 2), with: le16(magic))
        let directoryOffset = optionalOffset + (magic == 0x20b ? 112 : 96)
        file.replaceSubrange((directoryOffset + 8)..<(directoryOffset + 12), with: le32(importRVA))
        file.replaceSubrange((directoryOffset + 13 * 8)..<(directoryOffset + 13 * 8 + 4),
                             with: le32(delayRVA))

        let sectionHeader = optionalOffset + optionalSize
        var header = Data(count: 40)
        header.replaceSubrange(8..<12, with: le32(UInt32(section.count)))   // VirtualSize
        header.replaceSubrange(12..<16, with: le32(sectionRVA))             // VirtualAddress
        header.replaceSubrange(16..<20, with: le32(UInt32(section.count)))  // SizeOfRawData
        header.replaceSubrange(20..<24, with: le32(UInt32(headerSize)))     // PointerToRawData
        file.replaceSubrange(sectionHeader..<(sectionHeader + 40), with: header)

        return file + section
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }
}

final class PortableExecutableImportsTests: XCTestCase {
    private func write(_ data: Data, name: String = "game.exe") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-pe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// La distinción es el motivo de existir del lector: Unreal declara `d3d12.dll` como
    /// delay-load, nunca como enlace estático.
    func testReaderSeparatesLinkedFromDelayLoadedModules() throws {
        let url = try write(MinimalPortableExecutable.data(
            linked: ["dxgi.dll", "d3d11.dll"],
            delayed: ["d3d12.dll", "d3dcompiler_43.dll"]
        ))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let imports = try XCTUnwrap(PortableExecutableReader.imports(at: url))
        XCTAssertEqual(imports.linked, ["dxgi.dll", "d3d11.dll"])
        XCTAssertEqual(imports.delayed, ["d3d12.dll", "d3dcompiler_43.dll"])
        XCTAssertTrue(imports.delayLoads("d3d12.dll"))
        XCTAssertTrue(imports.delayLoads("D3D12.DLL"), "el módulo se compara sin distinguir mayúsculas")
        XCTAssertFalse(imports.delayLoads("d3d11.dll"), "d3d11 está enlazado, no diferido")
        XCTAssertTrue(imports.imports("d3d11.dll"))
    }

    func testReaderHandlesAnExecutableWithoutDelayLoads() throws {
        let url = try write(MinimalPortableExecutable.data(linked: ["d3d11.dll"], delayed: []))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let imports = try XCTUnwrap(PortableExecutableReader.imports(at: url))
        XCTAssertEqual(imports.linked, ["d3d11.dll"])
        XCTAssertTrue(imports.delayed.isEmpty)
        XCTAssertFalse(imports.delayLoads("d3d12.dll"))
    }

    func testReaderSupportsPE32AsWellAsPE32Plus() throws {
        let url = try write(MinimalPortableExecutable.data(
            linked: [], delayed: ["d3d12.dll"], magic: 0x10b
        ))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let imports = try XCTUnwrap(PortableExecutableReader.imports(at: url))
        XCTAssertTrue(imports.delayLoads("d3d12.dll"))
    }

    /// Un fichero que no es PE no puede hacer fallar una detección: se ignora en silencio.
    func testReaderRejectsSomethingThatIsNotAPortableExecutable() throws {
        let url = try write(Data("esto no es un ejecutable de Windows".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertNil(try PortableExecutableReader.imports(at: url))
    }
}
