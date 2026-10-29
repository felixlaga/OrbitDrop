// Standalone, off-screen integration tests. No NSApplication, windows, desktop automation or packages.
// swiftc -target arm64-apple-macosx13.0 Sources/OrbitDrop/MediaEngine.swift Tests/MediaEngineTests.swift -o /tmp/orbitdrop-engine-tests
// /tmp/orbitdrop-engine-tests [optional-artifact-directory]
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit

@main
struct MediaEngineTests {
    struct TestFailure: Error, CustomStringConvertible { let description: String }
    static var assertions = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw TestFailure(description: message) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { assertions += 1; return }
        throw TestFailure(description: "Expected error: \(message)")
    }
    static func image(width: Int = 1200, height: Int = 600, text: String = "ORBIT DROP 2026") -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.35, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 30, y: 30, width: width / 5, height: height / 5))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(min(width / 18, height / 5)), nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 50, y: height / 2); CTLineDraw(line, context)
        return context.makeImage()!
    }
    static func process(_ executable: String, _ args: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try check(process.terminationStatus == 0, "\(executable) failed: \(args)")
        return bytes
    }
    static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw TestFailure(description: "Independent ImageIO could not open \(url)") }
        return source
    }
    static func coloredPixelCount(_ image: CGImage, channel: Int) -> Int {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for y in 0..<image.height { for x in 0..<image.width {
            let i = y * context.bytesPerRow + x * 4
            if bytes[i + channel] > 200 && bytes[i + (channel + 1) % 3] < 80 && bytes[i + (channel + 2) % 3] < 80 { count += 1 }
        } }
        return count
    }
    static func makePDF(_ url: URL, scan: CGImage, pages: Int = 2) throws {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 288, height: 144)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, [kCGPDFContextTitle: "Fixture title", kCGPDFContextAuthor: "Private author"] as CFDictionary)!
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SEARCHABLE FIRST PAGE", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 20, y: 70); CTLineDraw(line, context); context.endPDFPage()
        if pages > 1 { context.beginPDFPage(nil); context.draw(scan, in: box); context.endPDFPage() }
        context.closePDF(); try (data as Data).write(to: url)
    }

    static func main() {
        do { try runTests() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    static func runTests() throws {
        let directory: URL
        if CommandLine.arguments.count > 1 { directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
        else { directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitDrop-engine-tests-\(UUID().uuidString)") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("OFFSCREEN integration artifacts: \(directory.path)")
        let fixture = image(), input = directory.appendingPathComponent("Original.png")
        try MediaEngine.writeImage(fixture, format: "PNG", to: input)
        let original = try Data(contentsOf: input)

        let expectedTypes = ["JPG": "public.jpeg", "PNG": "public.png", "WEBP": "org.webmproject.webp", "HEIC": "public.heic", "TIFF": "public.tiff", "AVIF": "public.avif", "BMP": "com.microsoft.bmp"]
        for format in ["JPG", "PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP"] {
            let outputs = try MediaEngine.convert(input, to: format)
            try check(outputs.count == 1, "\(format) should produce one image")
            let decoded = try source(outputs[0])
            try check(CGImageSourceGetType(decoded) as String? == expectedTypes[format], "Actual \(format) output type")
            let roundtrip = try MediaEngine.loadImage(outputs[0])
            try check(roundtrip.width == fixture.width && roundtrip.height == fixture.height, "\(format) round-trip dimensions")
            try check(outputs[0] != input, "Output must not reuse input")
            print("PASS actual \(format) encoding and decode")
        }
        try check(Data(contentsOf: input) == original, "Converting must not overwrite the input")
        let first = try MediaEngine.convert(input, to: "jpg")[0], second = try MediaEngine.convert(input, to: "jpg")[0]
        try check(first != second && first.deletingLastPathComponent().path == directory.path, "Adjacent non-overwriting output names")
        let retained = try Data(contentsOf: first)
        try rejects("writeImage must not overwrite an existing file") { try MediaEngine.writeImage(fixture, format: "jpg", to: first) }
        try check(Data(contentsOf: first) == retained, "writeImage refusal preserved bytes")

        let symlinkSource = directory.appendingPathComponent("Dangling.png")
        let dangling = directory.appendingPathComponent("Dangling.jpg")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: directory.appendingPathComponent("absent-target").path)
        try check(MediaEngine.uniqueSibling(for: symlinkSource, suffix: "", ext: "jpg") != dangling, "Dangling symlinks count as occupied paths")

        final class Results: @unchecked Sendable {
            let lock = NSLock(); var outputs: [URL] = []; var errors: [Error] = []
        }
        let parallel = Results()
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            do { let url = try MediaEngine.convert(input, to: "png")[0]; parallel.lock.lock(); parallel.outputs.append(url); parallel.lock.unlock() }
            catch { parallel.lock.lock(); parallel.errors.append(error); parallel.lock.unlock() }
        }
        try check(parallel.errors.isEmpty && Set(parallel.outputs).count == 6, "Concurrent conversions publish distinct outputs")
        print("PASS atomic nonoverwrite, symlinks and concurrent output publication")

        let oriented = directory.appendingPathComponent("Oriented.jpg")
        let orientationImage = image(width: 120, height: 80, text: "UP")
        let destination = CGImageDestinationCreateWithURL(oriented as CFURL, "public.jpeg" as CFString, 1, nil)!
        let metadata: [CFString: Any] = [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:29 12:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 139.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private photographer"]]
        CGImageDestinationAddImage(destination, orientationImage, metadata as CFDictionary)
        try check(CGImageDestinationFinalize(destination), "Metadata fixture encoded")
        let rotated = try MediaEngine.loadImage(oriented)
        try check(rotated.width == 80 && rotated.height == 120, "EXIF orientation applied at full resolution")
        let info = try MediaEngine.metadata(oriented)
        try check(info.contains { $0.0.contains("Latitude") }, "Metadata exposes GPS")
        let stripped = try MediaEngine.stripMetadata(oriented)
        let clean = CGImageSourceCopyPropertiesAtIndex(try source(stripped), 0, nil)! as NSDictionary
        try check(clean[kCGImagePropertyGPSDictionary] == nil, "Stripping removes GPS")
        let tiff = clean[kCGImagePropertyTIFFDictionary] as? NSDictionary
        try check(tiff?[kCGImagePropertyTIFFArtist] == nil, "Stripping removes TIFF artist")
        let exif = clean[kCGImagePropertyExifDictionary] as? NSDictionary
        try check(exif?[kCGImagePropertyExifDateTimeOriginal] == nil, "Stripping removes EXIF capture date")
        let cleanImage = try MediaEngine.loadImage(stripped)
        try check(cleanImage.width == 80 && cleanImage.height == 120, "Stripping preserves displayed orientation")
        print("PASS EXIF orientation and actual metadata removal")

        let scan = image(text: "SECOND PAGE SCANNED TEXT")
        let document = directory.appendingPathComponent("Two Pages.pdf")
        try makePDF(document, scan: scan)
        for format in ["jpg", "png"] {
            let pages = try MediaEngine.convert(document, to: format)
            try check(pages.count == 2, "PDF exports all pages")
            for (index, page) in pages.enumerated() {
                let bitmap = try MediaEngine.loadImage(page)
                try check(bitmap.width == 1200 && bitmap.height == 600, "PDF export at 300 DPI")
                try check(page.lastPathComponent == "Two Pages-page-\(index + 1).\(format)", "Multipage output naming")
            }
        }
        let single = directory.appendingPathComponent("Page 001.pdf")
        try makePDF(single, scan: scan, pages: 1)
        let singleJPEG = try MediaEngine.convert(single, to: "jpg")[0]
        try check(singleJPEG.lastPathComponent == "Page 001.jpg", "Single-page PDF preserves reference basename")
        let rotatedPDF = directory.appendingPathComponent("Rotated.pdf")
        let rotatedDocument = PDFDocument(url: single)!
        rotatedDocument.page(at: 0)!.rotation = 90
        try check(rotatedDocument.write(to: rotatedPDF), "Rotated PDF fixture written")
        let rotatedPage = try MediaEngine.loadImage(rotatedPDF)
        try check(rotatedPage.width == 600 && rotatedPage.height == 1200, "PDF intrinsic rotation applied")

        // Verify content coverage, not only the output bitmap's dimensions.
        let coverageData = NSMutableData(); var coverageBox = CGRect(x: 0, y: 0, width: 144, height: 72)
        let coverageContext = CGContext(consumer: CGDataConsumer(data: coverageData)!, mediaBox: &coverageBox, nil)!
        coverageContext.beginPDFPage(nil); coverageContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        coverageContext.fill(coverageBox); coverageContext.endPDFPage(); coverageContext.closePDF()
        let coverageDocument = PDFDocument(data: coverageData as Data)!
        for angle in [0, 90, 180, 270] {
            let page = coverageDocument.page(at: 0)!; page.rotation = angle
            let url = directory.appendingPathComponent("Coverage-\(angle).pdf")
            try check(coverageDocument.write(to: url), "Coverage fixture saved")
            let bitmap = try MediaEngine.loadImage(url)
            try check(coloredPixelCount(bitmap, channel: 0) > bitmap.width * bitmap.height * 99 / 100, "PDF content fills 300-DPI canvas at rotation \(angle)")
        }
        let coveragePage = coverageDocument.page(at: 0)!; coveragePage.rotation = 0
        let annotation = PDFAnnotation(bounds: coverageBox, forType: .square, withProperties: nil)
        annotation.color = .green; annotation.interiorColor = .green; coveragePage.addAnnotation(annotation)
        let annotationURL = directory.appendingPathComponent("Annotated.pdf")
        try check(coverageDocument.write(to: annotationURL), "Annotation fixture saved")
        let annotated = try MediaEngine.loadImage(annotationURL)
        try check(coloredPixelCount(annotated, channel: 1) > annotated.width * annotated.height * 95 / 100, "Visible annotations survive PDF rasterization")

        let pdfText = try MediaEngine.extractText(document)
        try check(pdfText.contains("SEARCHABLE FIRST PAGE"), "Searchable PDF text extracted")
        try check(pdfText.contains("SECOND PAGE SCANNED TEXT"), "OCR applied to scanned page in mixed PDF")
        let imageText = try MediaEngine.extractText(input)
        try check(imageText.contains("ORBIT DROP 2026"), "Vision OCR recognizes actual image pixels")
        let mixedData = NSMutableData(); var mixedBox = CGRect(x: 0, y: 0, width: 288, height: 144)
        let mixedContext = CGContext(consumer: CGDataConsumer(data: mixedData)!, mediaBox: &mixedBox, nil)!
        mixedContext.beginPDFPage(nil); mixedContext.draw(scan, in: mixedBox)
        let footer = CTLineCreateWithAttributedString(NSAttributedString(string: "Page 1", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 10, nil)]))
        mixedContext.textPosition = CGPoint(x: 250, y: 10); CTLineDraw(footer, mixedContext)
        mixedContext.endPDFPage(); mixedContext.closePDF()
        let mixedURL = directory.appendingPathComponent("Scan with footer.pdf"); try (mixedData as Data).write(to: mixedURL)
        let mixedText = try MediaEngine.extractText(mixedURL)
        try check(mixedText.contains("SECOND PAGE SCANNED TEXT") && mixedText.contains("Page 1"), "Native footer does not suppress OCR of a scan on the same page")
        let txt = try MediaEngine.convert(document, to: "TXT")[0]
        try check(String(contentsOf: txt, encoding: .utf8).contains("SECOND PAGE SCANNED TEXT"), "PDF to TXT contains OCR text")
        let pdfFromImage = try MediaEngine.convert(input, to: "PDF")[0]
        try check(PDFDocument(url: pdfFromImage)?.pageCount == 1, "Image to real PDF")
        print("PASS all PDF pages, 300 DPI, rotation, native text and mixed-page OCR")

        let textInput = directory.appendingPathComponent("Unicode.txt")
        let unicode = "Real DOCX & <XML> \"quotes\" — 日本語\nSecond paragraph"
        try Data(unicode.utf8).write(to: textInput)
        let textDOCX = try MediaEngine.convert(textInput, to: "DOCX")[0]
        _ = try process("/usr/bin/unzip", ["-t", textDOCX.path])
        let documentXML = String(data: try process("/usr/bin/unzip", ["-p", textDOCX.path, "word/document.xml"]), encoding: .utf8)!
        try check(documentXML.contains("&amp;") && documentXML.contains("&lt;XML&gt;"), "DOCX XML escapes content")
        try check(MediaEngine.extractText(textDOCX) == unicode, "Real OOXML ZIP round trip preserves Unicode text")
        let imageDOCX = try MediaEngine.convert(input, to: "DOCX")[0]
        _ = try process("/usr/bin/unzip", ["-t", imageDOCX.path])
        let embedded = try process("/usr/bin/unzip", ["-p", imageDOCX.path, "word/media/image.png"])
        try check(CGImageSourceCreateWithData(embedded as CFData, nil) != nil, "Image DOCX embeds a real PNG")
        try rejects("image-only DOCX must not silently become blank TXT") { _ = try MediaEngine.convert(imageDOCX, to: "TXT") }
        let pdfDOCX = try MediaEngine.convert(document, to: "DOCX")[0]
        try check(MediaEngine.extractText(pdfDOCX).contains("SECOND PAGE SCANNED TEXT"), "PDF to DOCX includes OCR text")
        let textPDF = try MediaEngine.convert(textInput, to: "PDF")[0]
        try check(PDFDocument(url: textPDF)?.string?.contains("Real DOCX") == true, "Text to PDF retains searchable text")

        let alternatives = directory.appendingPathComponent("alternate-package/word", isDirectory: true)
        try FileManager.default.createDirectory(at: alternatives, withIntermediateDirectories: true)
        let alternateXML = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"><w:body><mc:AlternateContent><mc:Choice Requires=\"w\"><w:p><w:r><w:t>Only once</w:t></w:r></w:p></mc:Choice><mc:Fallback><w:p><w:r><w:t>Only once</w:t></w:r></w:p></mc:Fallback></mc:AlternateContent></w:body></w:document>"
        try Data(alternateXML.utf8).write(to: alternatives.appendingPathComponent("document.xml"))
        let alternateDOCX = directory.appendingPathComponent("Alternate.docx")
        let zipProcess = Process(); zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.currentDirectoryURL = alternatives.deletingLastPathComponent(); zipProcess.arguments = ["-q", alternateDOCX.path, "word/document.xml"]
        try zipProcess.run(); zipProcess.waitUntilExit()
        try check(zipProcess.terminationStatus == 0 && MediaEngine.extractText(alternateDOCX) == "Only once", "DOCX compatibility alternative is included only once")

        let multipageTIFF = directory.appendingPathComponent("Multipage.tiff")
        let tiffDestination = CGImageDestinationCreateWithURL(multipageTIFF as CFURL, "public.tiff" as CFString, 2, nil)!
        CGImageDestinationAddImage(tiffDestination, fixture, nil); CGImageDestinationAddImage(tiffDestination, scan, nil)
        try check(CGImageDestinationFinalize(tiffDestination), "Multipage TIFF fixture saved")
        try rejects("multipage images must not silently lose frames") { _ = try MediaEngine.convert(multipageTIFF, to: "PDF") }
        try check(MediaEngine.convert(document, to: "TIFF").count == 2, "PDF to TIFF exports every page")
        let longText = directory.appendingPathComponent("Long.txt")
        try Data((0..<100).map { "Line \($0) preserves every page." }.joined(separator: "\n").utf8).write(to: longText)
        try check(MediaEngine.convert(longText, to: "PNG").count > 1, "Long text to images exports every laid-out page")
        print("PASS actual DOCX ZIP, XML, relationships, embedded image and Unicode round trip")

        let highQuality = directory.appendingPathComponent("Large.jpg")
        try MediaEngine.writeImage(fixture, format: "jpg", to: highQuality, quality: 1)
        let compressed = try MediaEngine.compress(highQuality, quality: 0.1)
        try check(Data(contentsOf: compressed).count < Data(contentsOf: highQuality).count, "Compression actually reduces bytes")
        try check(MediaEngine.loadImage(compressed).width == fixture.width, "JPEG compression retains dimensions")
        try rejects("unsupported format") { _ = try MediaEngine.convert(input, to: "fake") }
        try rejects("invalid quality") { _ = try MediaEngine.compress(input, quality: .nan) }
        try rejects("missing image") { _ = try MediaEngine.loadImage(directory.appendingPathComponent("missing.png")) }
        try rejects("document metadata is explicitly unsupported") { _ = try MediaEngine.stripMetadata(document) }
        let blank = directory.appendingPathComponent("Blank.png")
        try MediaEngine.writeImage(image(text: ""), format: "png", to: blank)
        try rejects("no text is an explicit error") { _ = try MediaEngine.extractText(blank) }

        // A later failed PDF page must roll back only outputs belonging to this conversion.
        let malformed = directory.appendingPathComponent("Oversized.pdf")
        let huge = PDFDocument(url: document)!
        huge.page(at: 1)!.setBounds(CGRect(x: 0, y: 0, width: 100_000, height: 100_000), for: .mediaBox)
        huge.page(at: 1)!.setBounds(CGRect(x: 0, y: 0, width: 100_000, height: 100_000), for: .cropBox)
        try check(huge.write(to: malformed), "Oversized PDF fixture written")
        try rejects("oversized later PDF page") { _ = try MediaEngine.convert(malformed, to: "png") }
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Oversized-page-1.png").path), "Failed batch rolls back earlier new pages")
        try check(Data(contentsOf: input) == original, "Input bytes remain unchanged after all operations")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try check(!files.contains { $0.hasPrefix(".orbitdrop-") }, "No incomplete staging files remain")
        print("PASS smaller compression, error paths and transactional PDF rollback")
        print("PASS \(assertions) integration assertions; no windows were created or displayed.")
    }
}
