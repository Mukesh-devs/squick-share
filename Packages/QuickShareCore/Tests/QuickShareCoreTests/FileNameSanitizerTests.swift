import Foundation
import XCTest
@testable import QuickShareCore

final class FileNameSanitizerTests: XCTestCase {
    func testPathSeparatorsAndTraversal() {
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("../../etc/passwd"), "___.._etc_passwd")
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent(".."), "__")
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("."), "_")
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("/absolute/path.txt"), "_absolute_path.txt")
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("..\\windows\\evil.exe"), "___windows_evil.exe")
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("a:b.txt"), "a_b.txt")
    }

    func testNoHiddenFiles() {
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent(".bashrc"), "_bashrc")
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("...dots"), "___dots")
    }

    func testControlAndBidiCharactersAreRemoved() {
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("a\u{0}b\u{7}c\nd.txt"), "abcd.txt")
        // "invoice\u{202E}fdp.exe" displays as "invoiceexe.pdf"
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("invoice\u{202E}fdp.exe"), "invoicefdp.exe")
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("\u{2066}x\u{2069}.jpg"), "x.jpg")
    }

    func testEmptyAndWhitespaceNames() {
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent(""), "file")
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("   "), "file")
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("\u{0}\u{1}"), "file")
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("  photo.jpg  "), "photo.jpg")
    }

    func testUnicodeIsKeptAndNormalized() {
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("फ़ोटो 🌅.jpg"), "फ़ोटो 🌅.jpg".precomposedStringWithCanonicalMapping)
        XCTAssertEqual(FileNameSanitizer.sanitizeComponent("e\u{301}.txt"), "\u{E9}.txt")
    }

    func testLengthLimitKeepsExtension() {
        let long = String(repeating: "a", count: 400) + ".jpeg"
        let result = FileNameSanitizer.sanitizeComponent(long)
        XCTAssertLessThanOrEqual(result.utf8.count, 255)
        XCTAssertTrue(result.hasSuffix(".jpeg"))
        let multibyte = String(repeating: "日", count: 200) + ".png"
        let result2 = FileNameSanitizer.sanitizeComponent(multibyte)
        XCTAssertLessThanOrEqual(result2.utf8.count, 255)
        XCTAssertTrue(result2.hasSuffix(".png"))
    }

    func testFolderSanitizing() {
        XCTAssertEqual(FileNameSanitizer.sanitizeFolder("Photos/2024"), ["Photos", "2024"])
        XCTAssertEqual(FileNameSanitizer.sanitizeFolder("Photos\\2024"), ["Photos", "2024"])
        XCTAssertEqual(FileNameSanitizer.sanitizeFolder("../../../etc"), ["etc"])
        XCTAssertEqual(FileNameSanitizer.sanitizeFolder("/abs/./x/../y"), ["abs", "x", "y"])
        XCTAssertEqual(FileNameSanitizer.sanitizeFolder(".hidden/a"), ["_hidden", "a"])
        XCTAssertEqual(FileNameSanitizer.sanitizeFolder(nil), [])
        XCTAssertEqual(FileNameSanitizer.sanitizeFolder("///"), [])
        XCTAssertEqual(FileNameSanitizer.sanitizeFolder(Array(repeating: "d", count: 100).joined(separator: "/")).count,
                       Limits.maxFolderDepth)
    }

    func testNumbering() {
        XCTAssertEqual(FileNameSanitizer.numbered("photo.jpg", 1), "photo (1).jpg")
        XCTAssertEqual(FileNameSanitizer.numbered("README", 2), "README (2)")
        XCTAssertEqual(FileNameSanitizer.numbered("archive.tar.gz", 3), "archive.tar (3).gz")
    }

    func testDestinationStaysInsideRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var created: [URL] = []
        let folder = try Destination.folder(root: root, components: ["Photos", "2024"], created: &created)
        XCTAssertEqual(folder.path, root.appendingPathComponent("Photos/2024").path)
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(try Destination.folder(root: root, components: [], created: &created).path, root.path)
    }

    func testSymlinkInDestinationIsRefused() throws {
        let root = try makeTempDirectory()
        let outside = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        var created: [URL] = []
        XCTAssertThrowsError(try Destination.folder(root: root, components: ["link", "x"], created: &created)) {
            XCTAssertEqual($0 as? DestinationError, .symlinkInPath)
        }
        XCTAssertEqual(allEntries(in: outside), [])
    }

    func testFileWithFolderNameGetsNumberedFolder() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("Photos").path, contents: Data())
        var created: [URL] = []
        let folder = try Destination.folder(root: root, components: ["Photos"], created: &created)
        XCTAssertEqual(folder.lastPathComponent, "Photos (1)")
    }

    func testMoveExclusiveNeverOverwrites() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var results: [String] = []
        for index in 0..<3 {
            let temp = root.appendingPathComponent(".tmp\(index)")
            try Data([UInt8(index)]).write(to: temp)
            results.append(try Destination.moveExclusive(temp, to: root, name: "photo.jpg").lastPathComponent)
        }
        XCTAssertEqual(results, ["photo.jpg", "photo (1).jpg", "photo (2).jpg"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo.jpg")), Data([0]))
    }
}
