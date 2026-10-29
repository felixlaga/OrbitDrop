import AppKit
import CoreText
import ImageIO
import PDFKit
import Vision
import Darwin

/// Synchronous file operations. Call from a worker queue; Vision and PDF rendering may take time.
enum MediaEngine {
    enum Failure: LocalizedError {
        case unsupported(String), unreadable(String), encoding(String), exists(String)
        case noText, invalidQuality, tooLarge, lockedPDF, noReduction
        var errorDescription: String? {
            switch self {
            case .unsupported(let message): return message
            case .unreadable(let name): return "Could not read \(name). The file may be damaged or unsupported."
            case .encoding(let message): return "Could not create the output: \(message)"
            case .exists(let name): return "\(name) already exists. Choose a different output filename."
            case .noText: return "No readable text was found in this file."
            case .invalidQuality: return "Quality must be a finite number between 0 and 1."
            case .tooLarge: return "This file is too large to process safely at full resolution."
            case .lockedPDF: return "Unlock the PDF before converting it."
            case .noReduction: return "This file could not be made smaller with these settings. The original was kept."
            }
        }
    }

    private static let fm = FileManager.default
    private static let maximumPixels = 100_000_000
    private static let types = ["jpg": "public.jpeg", "png": "public.png", "webp": "org.webmproject.webp",
                                "heic": "public.heic", "tiff": "public.tiff", "avif": "public.avif", "bmp": "com.microsoft.bmp"]
    private static func normalized(_ format: String) throws -> String {
        var value = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix(".") { value.removeFirst() }
        value = ["jpeg": "jpg", "tif": "tiff", "heif": "heic" ][value] ?? value
        guard types[value] != nil || ["pdf", "docx", "txt"].contains(value) else {
            throw Failure.unsupported("\(format.uppercased()) is not a supported output format.")
        }
        return value
    }
    private static func validateQuality(_ quality: Double) throws {
        guard quality.isFinite && (0...1).contains(quality) else { throw Failure.invalidQuality }
    }
    private static func checkSize(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, width <= maximumPixels / height else { throw Failure.tooLarge }
    }
    private static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }
    private static func isText(_ url: URL) -> Bool { ["txt", "docx"].contains(url.pathExtension.lowercased()) }

    static func loadImage(_ url: URL) throws -> CGImage {
        if isPDF(url) { return try rasterize(try pdf(url), index: 0) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        return try orientedImage(source, index: 0)
    }

    private static func orientedImage(_ source: CGImageSource, index: Int) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { throw Failure.unreadable("image dimensions") }
        try checkSize(width, height)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw Failure.unreadable("image pixels") }
        return image
    }

    private static func pdf(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable(url.lastPathComponent) }
        guard !document.isLocked else { throw Failure.lockedPDF }
        guard document.pageCount > 0 else { throw Failure.unreadable("empty PDF") }
        return document
    }

    private static func rasterize(_ document: PDFDocument, index: Int, dpi: CGFloat = 300) throws -> CGImage {
        guard let page = document.page(at: index), let ref = page.pageRef else { throw Failure.unreadable("PDF page \(index + 1)") }
        let box = page.bounds(for: .cropBox)
        let rotated = abs(ref.rotationAngle % 180) == 90
        let size = CGSize(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width * dpi / 72 <= CGFloat(maximumPixels), size.height * dpi / 72 <= CGFloat(maximumPixels) else { throw Failure.tooLarge }
        let width = Int(ceil(size.width * dpi / 72)), height = Int(ceil(size.height * dpi / 72))
        try checkSize(width, height)
        guard let context = rgbContext(width: width, height: height, alpha: false) else { throw Failure.encoding("PDF bitmap allocation failed") }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        // getDrawingTransform does not enlarge small pages to the requested pixel rectangle.
        // PDFKit applies page rotation/crop origin and includes annotation/form appearances.
        context.scaleBy(x: dpi / 72, y: dpi / 72)
        page.displaysAnnotations = true
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw Failure.encoding("PDF rasterization failed") }
        return image
    }

    private static func rgbContext(width: Int, height: Int, alpha: Bool) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)
    }

    private static func rgbImage(_ image: CGImage, opaque: Bool = false) throws -> CGImage {
        try checkSize(image.width, image.height)
        guard let context = rgbContext(width: image.width, height: image.height, alpha: !opaque) else { throw Failure.encoding("image allocation failed") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if opaque { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect) }
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw Failure.encoding("image rendering failed") }
        return result
    }

    static func writeImage(_ image: CGImage, format: String, to url: URL, quality: Double = 0.9) throws {
        try validateQuality(quality)
        let format = try normalized(format)
        let data: Data
        switch format {
        case "pdf": data = try imagePDF(image)
        case "docx": data = try docx(text: nil, image: image)
        case "txt": data = Data(try recognize(image).utf8)
        default: data = try encodedImage(image, format: format, quality: quality)
        }
        try publish(data, to: url)
    }

    private static func encodedImage(_ image: CGImage, format: String, quality: Double) throws -> Data {
        guard let type = types[format] else { throw Failure.unsupported("Unsupported image format: \(format)") }
        let clean = try rgbImage(image, opaque: format == "jpg" || format == "bmp")
        let destinations = CGImageDestinationCopyTypeIdentifiers() as! [String]
        if destinations.contains(type) {
            let data = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) {
                var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality,
                                               kCGImagePropertyOrientation: 1]
                if format == "tiff" { options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }
                CGImageDestinationAddImage(destination, clean, options as CFDictionary)
                if CGImageDestinationFinalize(destination) { return data as Data }
            }
        }
        guard format == "webp" || format == "avif" else { throw Failure.encoding("The system \(format.uppercased()) encoder failed.") }
        return try externalEncode(clean, format: format, quality: quality)
    }

    private static func codec(_ format: String) throws -> URL {
        let relative = format == "webp" ? "webp/cwebp" : "avif/avifenc"
        var roots: [URL] = []
        if let resource = Bundle.main.resourceURL { roots.append(resource.appendingPathComponent("Codecs")) }
        // Development executables do not have app resources. No Homebrew/system dependency is used.
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Codecs"))
        roots.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/Codecs"))
        for root in roots {
            let executable = root.appendingPathComponent(relative)
            if fm.isExecutableFile(atPath: executable.path) { return executable }
        }
        throw Failure.unsupported("The bundled \(format.uppercased()) encoder is missing. Rebuild the app with Resources/Codecs included.")
    }

    private static func externalEncode(_ image: CGImage, format: String, quality: Double) throws -> Data {
        let directory = try temporaryDirectory()
        defer { try? fm.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.png"), output = directory.appendingPathComponent("output.\(format)")
        try encodedImage(image, format: "png", quality: 1).write(to: input)
        let q = String(Int((quality * 100).rounded()))
        let args = format == "webp"
            ? ["-quiet", "-q", q, "-m", "6", "-mt", "-metadata", "none", input.path, "-o", output.path]
            : ["-q", q, "--qalpha", "100", "--speed", "6", "--jobs", "2", "--ignore-exif", "--ignore-xmp", input.path, output.path]
        _ = try run(try codec(format), args: args)
        let data = try Data(contentsOf: output)
        let valid = format == "webp"
            ? data.count >= 12 && String(data: data[0..<4], encoding: .ascii) == "RIFF" && String(data: data[8..<12], encoding: .ascii) == "WEBP"
            : data.count >= 16 && String(data: data[4..<8], encoding: .ascii) == "ftyp" && String(data: data[8..<12], encoding: .ascii) == "avif"
        guard valid else { throw Failure.encoding("The \(format.uppercased()) encoder returned an invalid file.") }
        return data
    }

    /// Pure filename selection; publication still checks atomically so concurrent conversions cannot clobber files.
    static func uniqueSibling(for source: URL, suffix: String, ext: String) -> URL {
        let directory = source.deletingLastPathComponent()
        let cleanSuffix = suffix.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        let cleanExtension = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).replacingOccurrences(of: "/", with: "")
        let stem = source.deletingPathExtension().lastPathComponent + cleanSuffix
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension(cleanExtension)
        var counter = 2
        while pathExists(candidate) {
            candidate = directory.appendingPathComponent("\(stem) \(counter)").appendingPathExtension(cleanExtension)
            counter += 1
        }
        return candidate
    }

    private static func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 // Includes dangling symlinks.
    }

    private static func publish(_ data: Data, to url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".orbitdrop-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: staging) }
        try data.write(to: staging, options: .withoutOverwriting)
        if renamex_np(staging.path, url.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            if code == EEXIST { throw Failure.exists(url.lastPathComponent) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    private static func adjacent(_ data: Data, source: URL, suffix: String = "", ext: String) throws -> URL {
        for _ in 0..<100 {
            let output = uniqueSibling(for: source, suffix: suffix, ext: ext)
            do { try publish(data, to: output); return output }
            catch Failure.exists { continue }
        }
        throw Failure.encoding("Too many simultaneous writes to this folder.")
    }

    static func convert(_ url: URL, to format: String) throws -> [URL] {
        let format = try normalized(format)
        if !isPDF(url) && !isText(url) { try requireSingleFrame(url) }
        let staging = url.deletingLastPathComponent().appendingPathComponent(".orbitdrop-batch-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var records: [(file: URL, suffix: String)] = []
        func stage(_ data: Data, suffix: String = "") throws {
            let file = staging.appendingPathComponent("\(records.count).\(format)")
            try data.write(to: file, options: .withoutOverwriting)
            records.append((file, suffix))
        }
        func stagePages(_ document: PDFDocument) throws {
            for index in 0..<document.pageCount {
                try autoreleasepool {
                    let data = try encodedImage(rasterize(document, index: index), format: format, quality: 0.9)
                    try stage(data, suffix: document.pageCount == 1 ? "" : "-page-\(index + 1)")
                }
            }
        }
        var outputs: [URL] = []
        if types[format] != nil && (isPDF(url) || isText(url)) {
            if isPDF(url) { try stagePages(pdf(url)) }
            else {
                guard let document = PDFDocument(data: try textPDF(extractText(url))) else { throw Failure.encoding("Text layout failed") }
                try stagePages(document)
            }
        } else {
            let data: Data
            switch format {
            case "txt": data = Data(try extractText(url).utf8)
            case "docx":
                data = isPDF(url) || isText(url) ? try docx(text: extractText(url), image: nil) : try docx(text: nil, image: loadImage(url))
            case "pdf":
                if isPDF(url) { _ = try pdf(url); data = try Data(contentsOf: url) }
                else if isText(url) { data = try textPDF(extractText(url)) }
                else { data = try imagePDF(loadImage(url)) }
            default: data = try encodedImage(loadImage(url), format: format, quality: 0.9)
            }
            try stage(data)
        }
        // Finish rendering every page before exposing any output. Once published, never remove a
        // path on failure: another process could have replaced it. Only the private staging tree
        // belongs to this operation. Separate sibling files cannot be published as one atomic set.
        for record in records {
            var published = false
            for _ in 0..<100 {
                let output = uniqueSibling(for: url, suffix: record.suffix, ext: format)
                if renamex_np(record.file.path, output.path, UInt32(RENAME_EXCL)) == 0 {
                    outputs.append(output); published = true; break
                }
                let code = errno
                if code == EEXIST { continue }
                let detail = NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
                if !outputs.isEmpty { throw Failure.encoding("\(detail) Already saved: \(outputs.map(\.lastPathComponent).joined(separator: ", ")).") }
                throw Failure.encoding(detail)
            }
            if !published { throw Failure.encoding("Too many simultaneous writes to this folder. Already saved \(outputs.count) file(s).") }
        }
        return outputs
    }

    static func extractText(_ url: URL) throws -> String {
        if url.pathExtension.lowercased() == "txt" {
            var encoding = String.Encoding.utf8
            return try String(contentsOf: url, usedEncoding: &encoding)
        }
        if url.pathExtension.lowercased() == "docx" {
            let data = try run(URL(fileURLWithPath: "/usr/bin/unzip"), args: ["-p", url.path, "word/document.xml"], maximumBytes: 32 * 1024 * 1024)
            let delegate = DocumentXMLReader()
            let parser = XMLParser(data: data); parser.delegate = delegate; parser.shouldResolveExternalEntities = false
            guard parser.parse() else { throw Failure.unreadable(url.lastPathComponent) }
            let text = delegate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.noText }
            return text
        }
        if isPDF(url) {
            let document = try pdf(url)
            var pages: [String] = []
            for index in 0..<document.pageCount {
                let native = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // A scanned page may also have a native footer. Always inspect visible pixels;
                // retain native text exactly and append OCR lines not already represented there.
                let recognized = try recognize(rasterize(document, index: index), allowEmpty: true)
                func comparable(_ text: String) -> String {
                    text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
                }
                let nativeComparable = comparable(native)
                let additions = recognized.components(separatedBy: .newlines).filter {
                    let candidate = comparable($0)
                    return !candidate.isEmpty && !nativeComparable.contains(candidate)
                }
                pages.append(([native] + additions).filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            let text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.noText }
            return text
        }
        return try recognize(loadImage(url))
    }

    private static func recognize(_ image: CGImage, allowEmpty: Bool = false) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        if text.isEmpty && !allowEmpty { throw Failure.noText }
        return text
    }

    static func metadata(_ url: URL) throws -> [(String, String)] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .typeIdentifierKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw Failure.unreadable(url.lastPathComponent) }
        var result = [("File", url.lastPathComponent), ("Format", url.pathExtension.uppercased()),
                      ("Size", ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file)),
                      ("Bytes", String(values.fileSize ?? 0))]
        let formatter = ISO8601DateFormatter()
        if let date = values.creationDate { result.append(("Created", formatter.string(from: date))) }
        if let date = values.contentModificationDate { result.append(("Modified", formatter.string(from: date))) }
        if let type = values.typeIdentifier { result.append(("Content type", type)) }
        if isPDF(url) {
            let document = try pdf(url); result.append(("Pages", String(document.pageCount)))
            if let page = document.page(at: 0) {
                let box = page.bounds(for: .cropBox)
                result.append(("Page size", String(format: "%.1f × %.1f pt", box.width, box.height)))
            }
            let attributes: [AnyHashable: Any] = document.documentAttributes ?? [:]
            for (key, value) in attributes.sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
                result.append((String(describing: key), String(describing: value)))
            }
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            result.append(("Frames", String(CGImageSourceGetCount(source))))
            if let w = properties[kCGImagePropertyPixelWidth as String], let h = properties[kCGImagePropertyPixelHeight as String] {
                result.append(("Dimensions", "\(w) × \(h) px"))
            }
            func append(_ dictionary: [String: Any], prefix: String = "") {
                for key in dictionary.keys.sorted() {
                    let label = prefix.isEmpty ? key : "\(prefix) · \(key)"
                    if let child = dictionary[key] as? [String: Any] { append(child, prefix: label.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))) }
                    else if let value = dictionary[key], !(value is Data), result.count < 250 { result.append((label, String(String(describing: value).prefix(2000)))) }
                }
            }
            append(properties)
        }
        return result
    }

    /// Retains the file's format and refuses to create a larger "compressed" copy.
    static func compress(_ url: URL, quality: Double) throws -> URL {
        try validateQuality(quality)
        let format = try normalized(url.pathExtension)
        let data: Data
        if format == "pdf" {
            let document = try pdf(url)
            if #available(macOS 13.4, *) {
                let directory = try temporaryDirectory(); defer { try? fm.removeItem(at: directory) }
                let output = directory.appendingPathComponent("optimized.pdf")
                let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: quality < 0.8]
                guard document.write(to: output, withOptions: options) else { throw Failure.encoding("PDF optimization failed") }
                data = try Data(contentsOf: output)
            } else { throw Failure.unsupported("PDF compression requires macOS 13.4 or later.") }
        } else {
            try requireSingleFrame(url)
            data = try encodedImage(loadImage(url), format: format, quality: quality)
        }
        let originalSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard data.count < originalSize else { throw Failure.noReduction }
        return try adjacent(data, source: url, suffix: "-compressed", ext: format)
    }

    /// Image pixels are re-encoded without source EXIF, GPS, IPTC or XMP. Orientation is baked in.
    static func stripMetadata(_ url: URL) throws -> URL {
        let format = try normalized(url.pathExtension)
        guard types[format] != nil else {
            throw Failure.unsupported("Metadata removal currently supports images. PDF and document metadata require document-specific sanitization.")
        }
        try requireSingleFrame(url)
        let data = try encodedImage(loadImage(url), format: format, quality: 1)
        return try adjacent(data, source: url, suffix: "-clean", ext: format)
    }

    private static func requireSingleFrame(_ url: URL) throws {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1 {
            throw Failure.unsupported("This operation would discard additional image frames. Convert individual frames first.")
        }
    }

    private static func imagePDF(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / 300, height: CGFloat(image.height) * 72 / 300)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure.encoding("PDF context failed") }
        context.beginPDFPage(nil); context.draw(image, in: box); context.endPDFPage(); context.closePDF()
        return data as Data
    }

    private static func textPDF(_ text: String) throws -> Data {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let string = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure.encoding("PDF text context failed") }
        let path = CGPath(rect: box.insetBy(dx: 54, dy: 54), transform: nil)
        var offset = 0
        while offset < string.length {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw Failure.encoding("Text cannot fit on a PDF page") }
            context.beginPDFPage(nil); CTFrameDraw(frame, context); context.endPDFPage()
            offset += visible.length
        }
        context.closePDF(); return data as Data
    }

    private static func xml(_ text: String) -> String {
        let allowed = text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF) }
        return String(String.UnicodeScalarView(allowed)).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func docx(text: String?, image: CGImage?) throws -> Data {
        var entries: [(String, Data)] = []
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        var body = ""
        if let text {
            body = text.components(separatedBy: .newlines).map { "<w:p><w:r><w:t xml:space=\"preserve\">\(xml($0))</w:t></w:r></w:p>" }.joined()
        }
        if let image {
            let ratio = min(5_943_600.0 / Double(image.width), 8_229_600.0 / Double(image.height))
            let cx = Int(Double(image.width) * ratio), cy = Int(Double(image.height) * ratio)
            body += """
            <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="1" name="Converted image"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="image.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdImage"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            """
            entries.append(("word/media/image.png", try encodedImage(image, format: "png", quality: 1)))
            entries.append(("word/_rels/document.xml.rels", Data((header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdImage\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image.png\"/></Relationships>").utf8)))
        }
        let document = header + """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080"/></w:sectPr></w:body></w:document>
        """
        entries.append(("word/document.xml", Data(document.utf8)))
        entries.append(("[Content_Types].xml", Data((header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>").utf8)))
        entries.append(("_rels/.rels", Data((header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdDocument\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>").utf8)))
        return try zip(entries)
    }

    /// ZIP STORE records are deliberately used: DOCX is a real OPC ZIP, without external tools or fake extensions.
    private static func zip(_ entries: [(String, Data)]) throws -> Data {
        var archive = Data(), central = Data()
        func u16(_ value: UInt16) -> Data { var little = value.littleEndian; return withUnsafeBytes(of: &little) { Data($0) } }
        func u32(_ value: UInt32) -> Data { var little = value.littleEndian; return withUnsafeBytes(of: &little) { Data($0) } }
        for (name, bytes) in entries {
            guard bytes.count < Int(UInt32.max), archive.count < Int(UInt32.max) else { throw Failure.tooLarge }
            let filename = Data(name.utf8), size = UInt32(bytes.count), offset = UInt32(archive.count)
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) } }
            crc ^= 0xFFFF_FFFF
            archive += u32(0x04034B50)
            for value: UInt16 in [20, 0x0800, 0, 0, 0x21] { archive += u16(value) }
            for value in [crc, size, size] { archive += u32(value) }
            archive += u16(UInt16(filename.count)); archive += u16(0)
            archive += filename; archive += bytes
            central += u32(0x02014B50)
            for value: UInt16 in [20, 20, 0x0800, 0, 0, 0x21] { central += u16(value) }
            for value in [crc, size, size] { central += u32(value) }
            central += u16(UInt16(filename.count))
            for _ in 0..<4 { central += u16(0) }
            central += u32(0); central += u32(offset); central += filename
        }
        guard archive.count < Int(UInt32.max), central.count < Int(UInt32.max) else { throw Failure.tooLarge }
        let start = UInt32(archive.count); archive += central
        archive += u32(0x06054B50); archive += u16(0); archive += u16(0)
        archive += u16(UInt16(entries.count)); archive += u16(UInt16(entries.count))
        archive += u32(UInt32(central.count)); archive += u32(start); archive += u16(0)
        return archive
    }

    private static func temporaryDirectory() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("OrbitDrop-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Redirect to files rather than pipes (which deadlock when a codec's diagnostic pipe fills).
    private static func run(_ executable: URL, args: [String], maximumBytes: Int = 16 * 1024 * 1024) throws -> Data {
        let directory = try temporaryDirectory(); defer { try? fm.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout"), stderr = directory.appendingPathComponent("stderr")
        fm.createFile(atPath: stdout.path, contents: nil); fm.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        let process = Process(); process.executableURL = executable; process.arguments = args
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        let complete = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in complete.signal() }
        try process.run()
        let deadline = Date().addingTimeInterval(180)
        while complete.wait(timeout: .now() + 0.2) == .timedOut {
            let outputSize = (try? stdout.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let errorSize = (try? stderr.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let exceededSize = outputSize > maximumBytes || errorSize > 1024 * 1024
            if exceededSize || Date() > deadline {
                if process.isRunning { process.terminate() }
                if complete.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
                }
                if exceededSize { throw Failure.tooLarge }
                throw Failure.encoding("\(executable.lastPathComponent) exceeded the time limit")
            }
        }
        guard process.terminationStatus == 0 else {
            let diagnostic = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
            throw Failure.encoding("\(executable.lastPathComponent): \(diagnostic.prefix(1000))")
        }
        let size = try stdout.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw Failure.tooLarge }
        return try Data(contentsOf: stdout)
    }
}

private final class DocumentXMLReader: NSObject, XMLParserDelegate {
    var text = ""
    private var readingText = false
    private var alternatives: [Bool] = []
    private var skippedDepth = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if skippedDepth > 0 { skippedDepth += 1; return }
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "AlternateContent" { alternatives.append(false) }
        if (local == "Choice" || local == "Fallback"), !alternatives.isEmpty {
            if alternatives[alternatives.count - 1] { skippedDepth = 1; return }
            alternatives[alternatives.count - 1] = true
        }
        if local == "t" { readingText = true }
        if local == "tab" { text += "\t" }
        if local == "br" || local == "cr" { text += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if readingText && skippedDepth == 0 { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skippedDepth > 0 { skippedDepth -= 1; return }
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "AlternateContent", !alternatives.isEmpty { alternatives.removeLast() }
        if local == "t" { readingText = false }
        if local == "p" { text += "\n" }
        if local == "tc" { text += "\t" }
    }
}
