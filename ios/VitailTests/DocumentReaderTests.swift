import PDFKit
import UIKit
import XCTest
@testable import Vitail

final class DocumentReaderTests: XCTestCase {
    private let councilText = """
    City of Melbourne
    Animal Registration Certificate
    Animal ID: 000123
    Dog name: Coco
    Expiry date: 9 April 2027
    """
    private let chipText = """
    Central Animal Records
    Identification Certificate
    Microchip number: 012 345 678 901 234
    Pet name: Coco
    """

    private func parse(_ text: String, kind: DocumentKind = .council) -> DocumentReadResult {
        DocumentFieldParser.parse(lines: DocumentReadLine.lines(text: text, page: 1, source: .pdfText),
                                  kind: kind, pagesRead: 1, source: .pdfText)
    }

    func testCouncilExtractsLabelledFieldsAndPreservesLeadingZeroes() {
        let result = parse(councilText)
        XCTAssertEqual(result.registrationNumber, "000123")
        XCTAssertEqual(result.councilName, "City of Melbourne")
        XCTAssertEqual(result.dogName, "Coco")
        XCTAssertEqual(result.validTo, "2027-04-09")
        XCTAssertNil(result.registryName)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.candidates.first(where: { $0.field == .registrationNumber })?.page, 1)
    }

    func testMicrochipHasNoExpiryAndNeverUsesCouncilNumber() {
        let result = parse(chipText + "\nRegistration number: 55555\nExpiry date: 9 April 2027", kind: .microchip)
        XCTAssertEqual(result.registrationNumber, "012345678901234")
        XCTAssertEqual(result.registryName, "Central Animal Records")
        XCTAssertEqual(result.dogName, "Coco")
        XCTAssertNil(result.validTo)
        XCTAssertNil(result.councilName)
        XCTAssertFalse(result.candidates.contains(where: { $0.field == .validTo }))
        let older = parse(chipText.replacingOccurrences(of: "012 345 678 901 234", with: "0123456789")
            .replacingOccurrences(of: "Pet name:", with: "Dog’s name:"), kind: .microchip)
        XCTAssertEqual(older.registrationNumber, "0123456789")
        XCTAssertEqual(older.dogName, "Coco")
    }

    func testMicrochipReadsNamedRegistryHeaderWithoutARegistryLabel() {
        let result = parse("""
        COMPANION TEST REGISTRY
        Certificate of Identification
        MICROCHIP REGISTRATION
        Animal name: Mishow
        Microchip number: 999000000001234
        Implanting clinic: Example Veterinary Clinic
        """, kind: .microchip)
        XCTAssertEqual(result.registryName, "COMPANION TEST REGISTRY")
        XCTAssertEqual(result.registrationNumber, "999000000001234")
        XCTAssertEqual(result.dogName, "Mishow")
        XCTAssertEqual(result.candidates.first { $0.field == .registryName }?.context, "COMPANION TEST REGISTRY")
    }

    func testRegistryHeaderDoesNotUseCertificateTitlesClinicOrBodyText() {
        let result = parse("""
        Microchip Registry
        Microchip Registration Certificate
        Example Veterinary Clinic
        Animal name: Mishow
        Microchip number: 999000000001234
        Happy Companion Registry
        No official registry or clinic has issued this record.
        """, kind: .microchip)
        XCTAssertNil(result.registryName)
        XCTAssertFalse(result.candidates.contains { $0.field == .registryName })
        XCTAssertEqual(result.dogName, "Mishow")
    }

    func testConflictingOrUnclearRegistryHeadersNeedManualReview() {
        let text = "Companion Test Registry\nSouthern Companion Registry\n" + chipText
            .replacingOccurrences(of: "Central Animal Records\n", with: "")
        let ambiguous = parse(text, kind: .microchip)
        XCTAssertNil(ambiguous.registryName)
        XCTAssertTrue(ambiguous.warnings.contains { $0.contains("More than one registry name") })
        let lines = DocumentReadLine.lines(text: text.replacingOccurrences(of: "Southern Companion Registry\n", with: ""),
                                          page: 1, source: .vision).map {
            DocumentReadLine(text: $0.text, page: 1, source: .vision, confidence: 0.2)
        }
        let unclear = DocumentFieldParser.parse(lines: lines, kind: .microchip, pagesRead: 1, source: .vision)
        XCTAssertNil(unclear.registryName)
        XCTAssertTrue(unclear.candidates.contains { $0.field == .registryName })
    }

    func testVisionLabelsReadValuesInTheirOwnColumn() {
        func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> DocumentReadLine {
            DocumentReadLine(text: text, page: 1, source: .vision, confidence: 0.99,
                             bounds: CGRect(x: x, y: y, width: width, height: 0.015))
        }
        let lines = [
            line("COMPANION TEST REGISTRY", x: 0.14, y: 0.92, width: 0.29),
            line("APPLICATION QA FIXTURE", x: 0.74, y: 0.92, width: 0.2),
            line("Certificate of Identification", x: 0.07, y: 0.85, width: 0.6),
            line("ANIMAL NAME", x: 0.1, y: 0.74, width: 0.13),
            line("REGISTRATION STATUS", x: 0.62, y: 0.74, width: 0.2),
            line("Mishow", x: 0.1, y: 0.70, width: 0.25),
            line("REGISTERED", x: 0.62, y: 0.70, width: 0.2),
            line("MICROCHIP NUMBER", x: 0.1, y: 0.62, width: 0.18),
            line("999000000001234", x: 0.1, y: 0.58, width: 0.4),
        ]
        let result = DocumentFieldParser.parse(lines: lines, kind: .microchip, pagesRead: 1, source: .vision)
        XCTAssertEqual(result.registryName, "COMPANION TEST REGISTRY")
        XCTAssertEqual(result.dogName, "Mishow")
        XCTAssertEqual(result.registrationNumber, "999000000001234")
        XCTAssertEqual(result.candidates.first { $0.field == .dogName }?.context, "ANIMAL NAME Mishow")
    }

    func testBlankVisionDogNameDoesNotConsumeTheNextFieldLabelOrItsNumber() {
        func line(_ text: String, x: CGFloat, y: CGFloat) -> DocumentReadLine {
            DocumentReadLine(text: text, page: 1, source: .vision, confidence: 0.99,
                             bounds: CGRect(x: x, y: y, width: 0.2, height: 0.015))
        }
        let lines = [
            line("COMPANION TEST REGISTRY", x: 0.1, y: 0.9),
            line("Certificate of Identification", x: 0.1, y: 0.85),
            line("ANIMAL NAME", x: 0.1, y: 0.74),
            line("REGISTRATION STATUS", x: 0.62, y: 0.74),
            line("MICROCHIP NUMBER", x: 0.1, y: 0.69),
            line("999000000001234", x: 0.1, y: 0.65),
        ]
        let result = DocumentFieldParser.parse(lines: lines, kind: .microchip, pagesRead: 1, source: .vision)
        XCTAssertNil(result.dogName)
        XCTAssertFalse(result.candidates.contains { $0.field == .dogName })
        XCTAssertEqual(result.registrationNumber, "999000000001234")
    }

    @MainActor func testOriginalMishowFixturePopulatesAllThreeReviewFieldsWithoutConfirming() async throws {
        // This supplied image is visibly fictional test data, not registration proof.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mishow-test-microchip-certificate", withExtension: "png"))
        let review = DocumentReviewModel()
        await review.read(data: try Data(contentsOf: url), filename: url.lastPathComponent, kind: .microchip)
        XCTAssertNil(review.errorMessage)
        XCTAssertEqual(review.registryName, "COMPANION TEST REGISTRY")
        XCTAssertEqual(review.registrationNumber, "999000000001234")
        XCTAssertEqual(review.dogName, "Mishow")
        XCTAssertEqual(review.readingAudit?.source, "APPLE_VISION")
        XCTAssertFalse(review.isConfirmed, "OCR suggestions must never confirm registration on the owner's behalf")
    }

    func testNeverUsesPaymentRenewalDueBirthdayOrUnlabelledDates() {
        for otherDate in ["Payment due: 9 April 2027", "Renewal due: 9 April 2027", "Date of birth: 9 April 2027",
                          "Registration date: 9 April 2027", "9 April 2027", "Expiry date:\nRenewal due: 9 April 2027"] {
            let result = parse(councilText.replacingOccurrences(of: "Expiry date: 9 April 2027", with: otherDate))
            XCTAssertNil(result.validTo, otherDate)
            XCTAssertTrue(result.warnings.contains(where: { $0.contains("expiry date") }))
        }
    }

    func testMultipleDogsNumbersAndExpiryDatesRemainUnresolved() {
        let result = parse(councilText + "\nAnimal ID: 000456\nDog name: Pip\nExpires: 10 April 2027")
        XCTAssertNil(result.registrationNumber)
        XCTAssertNil(result.dogName)
        XCTAssertNil(result.validTo)
        XCTAssertEqual(result.councilName, "City of Melbourne")
        XCTAssertEqual(result.warnings.filter { $0.contains("More than one") }.count, 3)
    }

    func testRepeatedSameValueAcrossPdfAndVisionIsNotAmbiguous() {
        let lines = DocumentReadLine.lines(text: councilText, page: 1, source: .pdfText)
            + DocumentReadLine.lines(text: councilText, page: 1, source: .vision)
        let result = DocumentFieldParser.parse(lines: lines, kind: .council, pagesRead: 1, source: .mixed)
        XCTAssertEqual(result.registrationNumber, "000123")
        XCTAssertEqual(result.validTo, "2027-04-09")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testBlankOrFilledApplicationIsNotAutofilledAsCompletedCertificate() {
        for text in ["Registration application form\nAnimal ID: ____\nDog name: ____\nExpiry date: ____",
                     councilText + "\nApplication for animal registration", "Renewal notice\n" + councilText] {
            let result = parse(text)
            XCTAssertNil(result.registrationNumber)
            XCTAssertNil(result.validTo)
            XCTAssertNil(result.dogName)
            XCTAssertTrue(result.warnings.first?.contains("not confirmation") == true)
        }
    }

    func testBlankFieldDoesNotConsumeTheNextPrintedInstructionAsDogName() {
        for label in ["Date of Birth of Animal", "Tick for Cross-Breed", "Breed", "Sex", "Microchip number",
                      "Registry name", "Council name", "Animal ID", "Registration status"] {
            let result = DocumentFieldParser.parse(lines: DocumentReadLine.lines(
                text: "Registration Certificate\nDog name\n" + label,
                page: 1, source: .pdfText), kind: .council, pagesRead: 1, source: .pdfText)
            XCTAssertNil(result.dogName)
            XCTAssertFalse(result.candidates.contains { $0.field == .dogName })
        }
    }

    func testOtherImageOrEmptyTextDoesNotFabricateFields() {
        for text in ["COFFEE\n$4.50\nPayment reference 000123", "", "Certificate of attendance\nCoco\n09/04/2027"] {
            let result = parse(text)
            XCTAssertNil(result.registrationNumber)
            XCTAssertNil(result.validTo)
            XCTAssertNil(result.councilName)
            XCTAssertNil(result.dogName)
            XCTAssertFalse(result.warnings.isEmpty)
        }
    }

    func testUnlabelledAndConfusableChipDigitsAreNotCorrected() {
        for chipLine in ["012345678901234", "Microchip number: O12345678901234", "Microchip number: 12345",
                         "Payment reference: 012345678901234", "Microchip number: 012345678901234 / 012345678901235"] {
            let result = parse("Identification Certificate\nCentral Animal Records\n" + chipLine, kind: .microchip)
            XCTAssertNil(result.registrationNumber, chipLine)
        }
    }

    func testInvalidDatesAreNotNormalizedAndLabelNextLineIsSupported() {
        for invalid in ["31/02/2027", "00/04/2027", "09/04/27", "2027", "April 2027", "9 April 2027 renewal due"] {
            XCTAssertNil(parse(councilText.replacingOccurrences(of: "9 April 2027", with: invalid)).validTo, invalid)
        }
        let result = parse(councilText.replacingOccurrences(of: "Animal ID: 000123", with: "Animal ID\n000123")
            .replacingOccurrences(of: "Expiry date: 9 April 2027", with: "Valid until\n2027-04-09"))
        XCTAssertEqual(result.registrationNumber, "000123")
        XCTAssertEqual(result.validTo, "2027-04-09")
    }

    func testLowConfidenceValueIsOnlyACandidate() {
        let lines = DocumentReadLine.lines(text: councilText, page: 1, source: .vision).map {
            DocumentReadLine(text: $0.text, page: 1, source: .vision, confidence: 0.2)
        }
        let result = DocumentFieldParser.parse(lines: lines, kind: .council, pagesRead: 1, source: .vision)
        XCTAssertNil(result.registrationNumber)
        XCTAssertNil(result.validTo)
        XCTAssertFalse(result.candidates.isEmpty)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("unclear") }))
        var separated = DocumentReadLine.lines(text: councilText.replacingOccurrences(of: "Animal ID: 000123", with: "Animal ID:\n000123"), page: 1, source: .vision)
        let valueIndex = separated.firstIndex(where: { $0.text == "000123" })!
        separated[valueIndex] = DocumentReadLine(text: "000123", page: 1, source: .vision, confidence: 0.2)
        XCTAssertNil(DocumentFieldParser.parse(lines: separated, kind: .council, pagesRead: 1, source: .vision).registrationNumber)
    }

    @MainActor func testTextPDFUsesTextLayerWithoutVision() async throws {
        let data = makePDF(text: councilText)
        let result = try await DocumentReader().read(data: data, filename: "council.pdf", kind: .council)
        XCTAssertEqual(result.source, .pdfText)
        XCTAssertEqual(result.pagesRead, 1)
        XCTAssertEqual(result.registrationNumber, "000123")
        XCTAssertEqual(result.validTo, "2027-04-09")
    }

    @MainActor func testRealVisionReadsGeneratedImageAndScannedPDF() async throws {
        // Generated only as unit fixtures; these do not stand in for issued-certificate research.
        let image = makeImage(text: councilText)
        let png = try XCTUnwrap(image.pngData())
        let fromImage = try await DocumentReader().read(data: png, filename: "fixture.png", kind: .council)
        XCTAssertEqual(fromImage.source, .vision)
        XCTAssertEqual(fromImage.registrationNumber, "000123")
        XCTAssertEqual(fromImage.validTo, "2027-04-09")
        let scanned = makePDF(image: image)
        XCTAssertTrue((PDFDocument(data: scanned)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let fromScan = try await DocumentReader().read(data: scanned, filename: "scan.pdf", kind: .council)
        XCTAssertEqual(fromScan.source, .vision)
        XCTAssertEqual(fromScan.registrationNumber, "000123")
        XCTAssertEqual(fromScan.validTo, "2027-04-09")
    }

    @MainActor func testVisiblePDFWidgetIsRenderedAndRead() async throws {
        let data = makePDF(text: councilText.replacingOccurrences(of: "Expiry date: 9 April 2027", with: ""))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let widget = PDFAnnotation(bounds: CGRect(x: 40, y: 270, width: 510, height: 44), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "Expiry"
        widget.widgetStringValue = "Expiry date: 9 April 2027"
        widget.font = UIFont.monospacedSystemFont(ofSize: 25, weight: .regular)
        widget.fontColor = .black
        page.addAnnotation(widget)
        let fixture = try XCTUnwrap(pdf.dataRepresentation())
        let result = try await DocumentReader().read(data: fixture, filename: "widget.pdf", kind: .council)
        XCTAssertEqual(result.source, .mixed)
        XCTAssertEqual(result.validTo, "2027-04-09")
    }

    func testReaderRejectsLimitsAndCancelledWork() async throws {
        do {
            _ = try await DocumentReader().read(data: Data(repeating: 0, count: 4 * 1024 * 1024 + 1), filename: "large.pdf", kind: .council)
            XCTFail("Accepted over-limit input")
        } catch { XCTAssertTrue(error is DocumentReadError) }
        do {
            _ = try await DocumentReader().read(data: Data("not a PDF".utf8), filename: "proof.pdf", kind: .council)
            XCTFail("Accepted invalid input")
        } catch { XCTAssertTrue(error is DocumentReadError) }
        let task = Task {
            try Task.checkCancellation()
            return try await DocumentReader().read(data: Data(), filename: "proof.png", kind: .council)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor private func makeImage(text: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1500, height: 1000), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1500, height: 1000))
            (text as NSString).draw(in: CGRect(x: 70, y: 60, width: 1360, height: 880),
                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 47, weight: .regular), .foregroundColor: UIColor.black])
        }
    }

    @MainActor private func makePDF(text: String? = nil, image: UIImage? = nil) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 500)).pdfData { context in
            context.beginPage()
            if let image { image.draw(in: CGRect(x: 0, y: 0, width: 600, height: 400)) }
            if let text {
                (text as NSString).draw(in: CGRect(x: 40, y: 40, width: 520, height: 400),
                    withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 21, weight: .regular), .foregroundColor: UIColor.black])
            }
        }
    }
}
