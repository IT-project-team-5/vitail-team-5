import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

protocol DocumentReading: Sendable {
    func read(data: Data, filename: String, kind: DocumentKind) async throws -> DocumentReadResult
}

enum DocumentReadSource: String, Sendable { case pdfText = "pdf_text", vision, mixed }
enum DocumentReadField: String, Sendable {
    case registrationNumber, councilName, registryName, dogName, validTo
}

struct DocumentReadCandidate: Sendable, Equatable {
    let field: DocumentReadField
    let value: String
    let page: Int
    let source: DocumentReadSource
    let context: String
    let confidence: Float?
}

/// Suggestions from document contents, never proof of registration or authenticity.
struct DocumentReadResult: Sendable {
    var registrationNumber: String? = nil
    var councilName: String? = nil
    var registryName: String? = nil
    var dogName: String? = nil
    var validTo: String? = nil
    let pagesRead: Int
    let source: DocumentReadSource
    var warnings: [String] = []
    var candidates: [DocumentReadCandidate] = []
}

enum DocumentReadError: LocalizedError {
    case tooLarge, invalidFile, encryptedPDF, pageLimit, imageLimit, unsupportedKind
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Choose a file no larger than 4 MB."
        case .invalidFile: return "This file could not be read. Choose a PDF, JPG or PNG."
        case .encryptedPDF: return "Choose a PDF without password protection."
        case .pageLimit: return "Choose a PDF with 1–20 pages."
        case .imageLimit: return "The image is too large to read. Choose a photo under 16 megapixels."
        case .unsupportedKind: return "Document reading is available for Council and microchip registration."
        }
    }
}

/// One serial queue bounds simultaneous image decoding; all PDF/Vision work stays off the main thread.
struct DocumentReader: DocumentReading {
    private static let queue = DispatchQueue(label: "com.vitail.document-reader", qos: .userInitiated)

    func read(data: Data, filename: String, kind: DocumentKind) async throws -> DocumentReadResult {
        guard kind != .vet else { throw DocumentReadError.unsupportedKind }
        guard data.count <= 4 * 1024 * 1024 else { throw DocumentReadError.tooLarge }
        try Task.checkCancellation()
        let cancellation = DocumentReadCancellation()
        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DocumentReadResult, Error>) in
                Self.queue.async {
                    do {
                        let result = try Self.process(data: data, kind: kind, cancellation: cancellation)
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch {
                        do { try cancellation.check(); continuation.resume(throwing: error) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }

    private static func process(data: Data, kind: DocumentKind, cancellation: DocumentReadCancellation) throws -> DocumentReadResult {
        try cancellation.check()
        var lines: [DocumentReadLine] = []
        var warnings: [String] = []
        var pagesRead = 1
        var usedText = false
        var usedVision = false
        // Inspect actual bytes, not a user-controlled filename extension.
        if data.starts(with: Data("%PDF-".utf8)) {
            guard let pdf = PDFDocument(data: data) else { throw DocumentReadError.invalidFile }
            guard !pdf.isEncrypted, !pdf.isLocked else { throw DocumentReadError.encryptedPDF }
            guard (1...20).contains(pdf.pageCount) else { throw DocumentReadError.pageLimit }
            pagesRead = pdf.pageCount
            for index in 0..<pdf.pageCount {
                try cancellation.check()
                try autoreleasepool {
                    guard let page = pdf.page(at: index) else { throw DocumentReadError.invalidFile }
                    let text = page.string ?? ""
                    let pageLines = DocumentReadLine.lines(text: String(text.prefix(20_000)), page: index + 1, source: .pdfText)
                    if text.count > 20_000 { warnings.append("Page \(index + 1) contains more text than can be inspected. Check it manually.") }
                    if !pageLines.isEmpty { usedText = true; lines.append(contentsOf: pageLines) }
                    let partial = DocumentFieldParser.parse(lines: pageLines, kind: kind, pagesRead: 1, source: .pdfText)
                    let missing = partial.registrationNumber == nil || partial.dogName == nil
                        || (kind == .council ? partial.councilName == nil || partial.validTo == nil : partial.registryName == nil)
                    if missing {
                        usedVision = true
                        lines.append(contentsOf: try recognize(render(page), page: index + 1, orientation: .up, cancellation: cancellation))
                    }
                }
            }
        } else {
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png"].contains(type),
                      CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw DocumentReadError.invalidFile }
                guard width > 0, height > 0, width <= 16_000_000 / height else { throw DocumentReadError.imageLimit }
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DocumentReadError.invalidFile }
                let orientation = CGImagePropertyOrientation(rawValue: (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1) ?? .up
                usedVision = true
                lines = try recognize(image, page: 1, orientation: orientation, cancellation: cancellation)
            }
        }
        try cancellation.check()
        let source: DocumentReadSource = usedVision ? (usedText ? .mixed : .vision) : .pdfText
        var result = DocumentFieldParser.parse(lines: lines, kind: kind, pagesRead: pagesRead, source: source)
        result.warnings.append(contentsOf: warnings)
        return result
    }

    private static func render(_ page: PDFPage) throws -> CGImage {
        guard let ref = page.pageRef else { throw DocumentReadError.invalidFile }
        let box = ref.getBoxRect(.mediaBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { throw DocumentReadError.invalidFile }
        let rotated = abs(ref.rotationAngle) % 180 != 0
        let size = CGSize(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
        let scale = min(2.5, 3200 / max(size.width, size.height))
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw DocumentReadError.invalidFile
        }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.scaleBy(x: scale, y: scale)
        // PDFKit applies page rotation and includes visible annotation/widget values.
        // Applying CGPDFPage's transform as well would rotate the page twice.
        page.displaysAnnotations = true
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw DocumentReadError.invalidFile }
        return image
    }

    private static func recognize(_ image: CGImage, page: Int, orientation: CGImagePropertyOrientation,
                                  cancellation: DocumentReadCancellation) throws -> [DocumentReadLine] {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false // Identifiers must not be corrected into words.
        try cancellation.install(request)
        defer { cancellation.clear() }
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        try cancellation.check()
        // Vision may put a printed label and its adjacent value in separate observations.
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) < 0.012 { return $0.boundingBox.minX < $1.boundingBox.minX }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
        var rows: [(y: CGFloat, text: String, confidence: Float)] = []
        for observation in observations.prefix(2000) {
            guard let candidate = observation.topCandidates(1).first else { continue }
            if let last = rows.last, abs(last.y - observation.boundingBox.midY) < 0.012 {
                rows[rows.count - 1].text += " " + candidate.string
                rows[rows.count - 1].confidence = min(last.confidence, candidate.confidence)
            } else { rows.append((observation.boundingBox.midY, candidate.string, candidate.confidence)) }
        }
        return rows.map { DocumentReadLine(text: String($0.text.prefix(500)), page: page, source: .vision, confidence: $0.confidence) }
    }
}

private final class DocumentReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRecognizeTextRequest?
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func install(_ request: VNRecognizeTextRequest) throws {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        self.request = request
        lock.unlock()
    }
    func clear() { lock.lock(); request = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let active = request; lock.unlock()
        active?.cancel()
    }
}

struct DocumentReadLine: Sendable {
    let text: String
    let page: Int
    let source: DocumentReadSource
    var confidence: Float? = nil
    static func lines(text: String, page: Int, source: DocumentReadSource) -> [Self] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(2000).map { Self(text: String($0.prefix(500)), page: page, source: source) }
    }
}

/// Intentionally label-based: dates, payment references and unlabelled numbers are not guessed.
enum DocumentFieldParser {
    private static let numberLabel = #"(?:animal\s*(?:id|number|no\.?)|(?:animal|pet|dog|council)\s+registration\s*(?:number|no\.?|id)|registration\s*(?:number|no\.?|id))"#
    private static let chipLabel = #"(?:microchip|micro-chip|chip)\s*(?:number|no\.?|id)"#
    private static let nameLabel = #"(?:(?:dog|pet|animal)(?:['’]s)?\s*name|name\s+of\s+(?:dog|pet|animal))"#
    private static let expiryLabel = #"(?:(?:registration\s+)?(?:expiry\s*date|date\s+of\s+expiry|expires(?:\s+on)?|valid\s+(?:to|until|through)))"#

    static func parse(lines: [DocumentReadLine], kind: DocumentKind, pagesRead: Int, source: DocumentReadSource) -> DocumentReadResult {
        var result = DocumentReadResult(pagesRead: pagesRead, source: source)
        var candidates: [DocumentReadCandidate] = []
        let joined = lines.map(\.text).joined(separator: "\n")
        let form = matches(#"\b(?:application\s+form|application\s+for|registration\s+(?:application|form|notice)|renewal\s+notice)\b"#, joined)
        let certificate = matches(#"\b(?:certificate|registration\s+confirmation|registration\s+record|registration\s+details|registered)\b"#, joined)
        func add(_ field: DocumentReadField, _ value: String?, _ line: DocumentReadLine) {
            guard let value, !value.isEmpty else { return }
            let candidate = DocumentReadCandidate(field: field, value: value, page: line.page, source: line.source,
                                                   context: String(line.text.prefix(160)), confidence: line.confidence)
            if !candidates.contains(candidate) { candidates.append(candidate) }
        }
        let labels = [numberLabel, chipLabel, nameLabel, expiryLabel, #"(?:(?:issuing|local)\s+)?council(?:\s+name)?|municipality|(?:microchip\s+)?registry(?:\s+name)?"#].joined(separator: "|")
        for (index, line) in lines.enumerated() {
            let nextLine = index + 1 < lines.count && lines[index + 1].page == line.page ? lines[index + 1] : nil
            let next = nextLine?.text
            var provenance = line
            if let nextLine, matches("^\\s*(?:" + labels + ")\\s*[:#=]?\\s*$", line.text) {
                provenance = DocumentReadLine(text: line.text + " " + nextLine.text, page: line.page, source: line.source,
                    confidence: line.confidence == nil && nextLine.confidence == nil ? nil : min(line.confidence ?? 1, nextLine.confidence ?? 1))
            }
            if let value = labelled(kind == .council ? numberLabel : chipLabel, line.text, next: next) {
                if kind == .microchip {
                    let normalized = value.filter { !$0.isWhitespace && $0 != "-" }
                    if matches(#"^(?:[0-9]{10}|[0-9]{15})$"#, normalized) { add(.registrationNumber, normalized, provenance) }
                } else if value.count <= 100, matches(#"^[A-Za-z0-9][A-Za-z0-9 -]*$"#, value), matches("[0-9]", value),
                          !matches(#"\b(?:microchip|expiry|expires|dog|pet|animal|council|registration|payment|due|birth)\b"#, value) {
                    add(.registrationNumber, value, provenance)
                }
            }
            if let value = labelled(nameLabel, line.text, next: next), validName(value) { add(.dogName, value, provenance) }
            if kind == .council {
                if let value = labelled(#"(?:(?:issuing|local)\s+)?council(?:\s+name)?|municipality"#, line.text, next: next), validName(value) {
                    add(.councilName, value, provenance)
                } else if matches(#"^(?:City\s+of\s+[\p{L} '-]+|[\p{L} '-]+\s+(?:City|Shire|Borough)\s+Council)$"#, line.text), line.text.count <= 100 {
                    add(.councilName, line.text, line)
                }
                if let value = labelled(expiryLabel, line.text, next: next) { add(.validTo, date(value), provenance) }
            } else {
                if let value = labelled(#"(?:microchip\s+)?registry(?:\s+name)?"#, line.text, next: next), validName(value) { add(.registryName, registry(value), provenance) }
                if let known = knownRegistry(line.text) { add(.registryName, known, line) }
            }
        }
        result.candidates = Array(candidates.prefix(40))
        guard !form, certificate else {
            result.warnings = [form ? "This appears to be an application or renewal notice, not confirmation of completed registration. Choose your certificate or completed-registration record."
                : "A completed-registration certificate could not be identified. Check that this is the correct document."]
            if lines.isEmpty { result.warnings.append("No readable text was found. Try a clearer photo or a text PDF.") }
            return result
        }
        func resolve(_ field: DocumentReadField, label: String) -> String? {
            let values = candidates.filter { $0.field == field }
            let distinct = Dictionary(grouping: values, by: { $0.value.lowercased() })
            if distinct.count > 1 { result.warnings.append("More than one \(label) was found. Choose the value for this dog."); return nil }
            guard let value = values.first else { result.warnings.append("The \(label) could not be read. Enter it from the document."); return nil }
            guard values.contains(where: { ($0.confidence ?? 1) >= 0.65 }) else {
                result.warnings.append("The \(label) is unclear. Check it on the original document."); return nil
            }
            return value.value
        }
        result.registrationNumber = resolve(.registrationNumber, label: kind == .council ? "animal registration number" : "microchip number")
        result.dogName = resolve(.dogName, label: "dog's name")
        if kind == .council {
            result.councilName = resolve(.councilName, label: "council name")
            result.validTo = resolve(.validTo, label: "labelled expiry date")
        } else { result.registryName = resolve(.registryName, label: "registry name") }
        return result
    }

    private static func labelled(_ label: String, _ text: String, next: String?) -> String? {
        guard let expression = try? NSRegularExpression(pattern: "^\\s*(?:" + label + ")\\s*(?:[:#=]\\s*|\\s+)(.+?)\\s*$", options: .caseInsensitive) else { return nil }
        if let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            let value = String(text[range]).trimmingCharacters(in: .whitespaces)
            return value.contains(":") || value.contains("_") ? nil : value
        }
        if matches("^\\s*(?:" + label + ")\\s*[:#=]?\\s*$", text), let next,
           !next.contains(":"), !next.contains("_") { return next.trimmingCharacters(in: .whitespaces) }
        return nil
    }

    private static func validName(_ value: String) -> Bool {
        value.count <= 100 && matches(#"^[\p{L}][\p{L}\p{N} '’&().-]*$"#, value)
            && !matches(#"^(?:name|number|unknown|n/?a|date\s+of\s+birth.*|breed|sex|gender|colou?r|please\s+.*|enter\s+.*|tick\s+.*|select\s+.*)$"#, value)
    }
    private static func knownRegistry(_ value: String) -> String? {
        if matches(#"\b(?:Central Animal Records|CAR)\b"#, value) { return "Central Animal Records" }
        if matches(#"\b(?:Australasian Animal Registry|AAR)\b"#, value) { return "Australasian Animal Registry" }
        return nil
    }
    private static func registry(_ value: String) -> String { knownRegistry(value) ?? value }
    private static func date(_ value: String) -> String? {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(#"^(?:[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}|[0-9]{1,2}[/.-][0-9]{1,2}[/.-][0-9]{4}|[0-9]{1,2}\s+[A-Za-z]{3,9}\s+[0-9]{4}|[A-Za-z]{3,9}\s+[0-9]{1,2},?\s+[0-9]{4})$"#, input) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["yyyy-MM-dd", "d/M/yyyy", "d-M-yyyy", "d.M.yyyy", "d MMM yyyy", "d MMMM yyyy", "MMM d yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMMM d, yyyy"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: input) { formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: parsed) }
        }
        return nil
    }
    private static func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
