import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DocumentSubmissionView: View {
    @Environment(\.isPresented) private var isPresented
    @StateObject private var model: DocumentViewModel
    private let dogID: Int
    private let kind: DocumentKind
    private let expectedEntitlementID: Int?
    private let needsExpiry: Bool
    @StateObject private var review: DocumentReviewModel
    private let onSubmitted: () async -> Void
    private let onChanged: () async -> Void
    @State private var method: DocumentEvidenceMethod = .upload
    @State private var eventDate = Date()
    @State private var importingFile = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var attachmentGeneration = UUID()
    @State private var fileData: Data?
    @State private var filename: String?
    @State private var validationMessage: String?
    @State private var isEditing = false
    @State private var preview: DocumentPreviewFile?
    @State private var previewDirectory: URL?
    @State private var isDownloading = false
    @State private var isVisible = true
    @State private var choosingExpiry = false
    @State private var expiryChoice = Date()

    init(service: any DocumentServing = DocumentService(), session: SessionStore? = nil,
         initialDogID: Int, initialKind: DocumentKind,
         expectedEntitlementID: Int? = nil, needsExpiry: Bool = false,
         initialMethod: DocumentEvidenceMethod = .upload,
         reader: any DocumentReading = DocumentReader(),
         onSubmitted: @escaping () async -> Void = {}, onChanged: @escaping () async -> Void = {}) {
        _model = StateObject(wrappedValue: DocumentViewModel(service: service, session: session))
        _method = State(initialValue: initialMethod)
        _review = StateObject(wrappedValue: DocumentReviewModel(reader: reader))
        self.expectedEntitlementID = expectedEntitlementID
        self.needsExpiry = needsExpiry
        dogID = initialDogID
        kind = initialKind
        self.onSubmitted = onSubmitted
        self.onChanged = onChanged
    }

    private var currentSubmission: DocumentSubmission? {
        model.currentSubmission(dogID: dogID, kind: kind, entitlementID: expectedEntitlementID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                if let dashboard = model.dashboard {
                    if let dog = dashboard.dogs.first(where: { $0.id == dogID }) {
                        HStack(spacing: AppSpacing.small) {
                            AvatarView(url: dog.photo, name: dog.name, systemImage: "dog.fill", size: 44)
                            Text(dog.name).font(.headline)
                        }
                        tutorial
                        if let submission = currentSubmission, !isEditing {
                            submissionCard(submission)
                            Button(kind == .vet ? "Add another check-up" : "Update submission") { isEditing = true }
                        } else {
                            submissionForm
                        }
                    } else {
                        Text("This dog is no longer available. Close this page and refresh your Quests.")
                            .foregroundStyle(AppColors.secondaryText)
                    }
                } else if model.isLoading {
                    ProgressView("Loading…")
                } else {
                    Button("Try again") { Task { await model.load() } }
                }
                if let message = validationMessage ?? model.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(AppColors.error)
                    if model.errorMessage != nil, model.dashboard != nil {
                        Button("Refresh") { Task { await model.load() } }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.large)
        }
        .background(AppColors.background)
        .foregroundStyle(AppColors.primaryText)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isSubmitting || model.collectingID != nil || !model.isActive)
        .task { await model.load() }
        .onChange(of: method) { _, _ in
            clearAttachment()
            validationMessage = nil
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.pdf, .jpeg, .png]) { result in
            guard model.isActive else { return }
            do { try importFile(result.get()) }
            catch { validationMessage = error.localizedDescription }
        }
        .onChange(of: photoSelection) { _, selected in
            guard let selected else { return }
            clearAttachment()
            let generation = UUID()
            attachmentGeneration = generation
            Task { await importPhoto(selected, generation: generation) }
        }
        .sheet(item: $preview, onDismiss: clearPreview) { file in
            DocumentPreviewController(url: file.url).ignoresSafeArea()
        }
        .sheet(isPresented: $choosingExpiry) {
            NavigationStack {
                DatePicker("Expiry date", selection: $expiryChoice, displayedComponents: .date)
                    .datePickerStyle(.graphical).padding()
                    .environment(\.calendar, DogBirthday.calendar)
                    .environment(\.timeZone, DogBirthday.timeZone)
                    .navigationTitle("Expiry date")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingExpiry = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Use this date") {
                                review.expiryText = DocumentRegistration.expiryInputText(DogBirthday.string(from: expiryChoice))
                                choosingExpiry = false
                            }
                        }
                    }
            }.presentationDetents([.medium, .large])
        }
        .onAppear { isVisible = true }
        .onChange(of: isPresented) { _, presented in
            if !presented { stop() }
        }
        .onChange(of: model.isActive) { _, active in
            if !active { clearSensitiveData() }
        }
        .onDisappear {
            isVisible = false
            // Presenting a file picker or Quick Look is not the end of this screen.
            if !isPresented { stop() }
        }
    }

    private var tutorial: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            switch kind {
            case .council:
                Text(needsExpiry ? "Update the expiry on your existing registration. This does not create another reward." : "Your registration stays current through the expiry date on your document. Submit renewed proof after it expires.")
                    .foregroundStyle(AppColors.secondaryText)
                guide("Already registered?", "Find the Animal ID or registration number on your council's current certificate or registration confirmation. Ask your council for a copy if it is missing. Do not use a payment reference or tag number.")
                guide("Not registered yet?", "Microchip your dog, then apply online or by paper form to the council where your dog lives. Wait for its completed-registration confirmation before submitting here.")
                Link("Find your council", destination: URL(string: "https://www.vec.vic.gov.au/electoral-boundaries/which-boundaries-cover-where-i-live")!)
                Link("City of Melbourne: apply or contact the council", destination: URL(string: "https://ablis.business.gov.au/service/vic/registration-of-cats-and-dogs-city-of-melbourne/28570")!)
            case .microchip:
                guide("Already microchipped?", "Find the number in your pet's records or ask a vet to scan your dog. Use Pet Address to find the registry. For a certificate: CAR → My Animals → your dog → Generate Certificate; AAR → sign in → print registration certificate.")
                Link("Find your registry with Pet Address", destination: URL(string: "https://www.petaddress.com.au/")!)
                HStack(spacing: AppSpacing.large) {
                    Link("CAR help", destination: URL(string: "https://car.com.au/apps/help-center")!)
                    Link("AAR pet owners", destination: URL(string: "https://www.aar.org.au/pet-owners/")!)
                }
                guide("Not registered yet?", "Book a vet for microchipping and registration. Already has a chip? Ask the registry to register or transfer it to you. Finish any required verification or transfer before submitting.")
                Link("Victoria's microchipping guide", destination: URL(string: "https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/microchipping-of-dogs-cats-and-horses/microchipping-of-dogs-and-cats")!)
            case .vet:
                guide("After your check-up", "Add a photo of your dog's vet visit evidence and the visit date. You can earn 200 points for up to two check-ups per year, at least 60 days apart.")
            }
        }
        .font(.subheadline)
    }

    private func guide(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(AppColors.secondaryText)
        }
    }

    private var submissionForm: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            if kind != .vet {
                Picker("Submission method", selection: $method) {
                    ForEach(DocumentEvidenceMethod.allCases) { method in Text(method.rawValue).tag(method) }
                }.pickerStyle(.segmented)
            }
            if kind == .vet || method == .upload { attachmentPicker }
            if kind == .vet {
                DatePicker("Visit date", selection: $eventDate, in: ...Date(), displayedComponents: .date)
                    .environment(\.calendar, DogBirthday.calendar)
                    .environment(\.timeZone, DogBirthday.timeZone)
            } else if review.isReading {
                HStack {
                    ProgressView("Reading document…")
                    Spacer()
                    Button("Cancel") { review.cancelReading() }
                }
            } else if method == .details || (fileData != nil && review.didRead) {
                reviewFields
            }
            PrimaryButton(title: model.isSubmitting ? "Submitting…" : "Submit",
                          isLoading: model.isSubmitting,
                          isDisabled: review.isReading || (kind != .vet && !review.isConfirmed)) {
                Task { await submit() }
            }
            Text("Submitted details are self-reported and may be checked later.")
                .font(.caption).foregroundStyle(AppColors.secondaryText)
            if isEditing {
                Button("Cancel") { isEditing = false; validationMessage = nil }
            }
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
    }

    private var reviewFields: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text(method == .upload ? "Check document details" : "Registration details").font(.headline)
            if let error = review.errorMessage {
                Text(error).font(.footnote).foregroundStyle(AppColors.secondaryText)
                Button("Read again") { startReading() }
            } else if method == .upload && review.needsCorrection {
                Text("Some details could not be read. Check and complete the fields below.")
                    .font(.footnote).foregroundStyle(AppColors.secondaryText)
            }
            if kind == .council {
                entryField("Council name", text: $review.councilName)
                entryField("Animal ID / registration number", text: $review.registrationNumber)
                Button {
                    expiryChoice = DocumentRegistration.normalizedExpiry(review.expiryText).flatMap(DogBirthday.date) ?? Date()
                    choosingExpiry = true
                } label: {
                    HStack {
                        Text("Expiry date")
                        Spacer()
                        Text(DocumentRegistration.normalizedExpiry(review.expiryText).map(DogBirthday.display) ?? "Select expiry date")
                        Image(systemName: "calendar")
                    }.font(.subheadline)
                }
                Text("Use the printed expiry date. Registration is valid through that day in Melbourne time.")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            } else {
                entryField(method == .upload ? "Microchip number on certificate" : "15-digit microchip number", text: $review.registrationNumber)
                    .keyboardType(.numbersAndPunctuation)
                entryField("Registry name (optional)", text: $review.registryName)
            }
            if method == .upload { entryField("Dog name on document (optional)", text: $review.dogName) }
            Toggle("I checked these details against my dog's document", isOn: $review.isConfirmed)
                .font(.subheadline)
        }
    }

    private func entryField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(title).font(.subheadline.weight(.medium))
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var attachmentPicker: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text(kind == .vet ? "Upload visit evidence" : "Upload proof").font(.headline)
            if kind != .vet {
                Text(kind == .council
                     ? "Show the council, your dog, registration number and expiry date on a certificate or completed-registration email."
                     : "Show the registry, microchip number and dog or owner details on your registration certificate.")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                Button { importingFile = true } label: { Label("Choose file", systemImage: "doc.badge.plus") }
            }
            PhotosPicker(selection: $photoSelection, matching: .images) {
                Label("Choose photo", systemImage: "photo.badge.plus")
            }
            Text(kind == .vet ? "A clear photo, up to 4 MB." : "PDF, JPG or PNG · up to 4 MB. Photos and screenshots are welcome.")
                .font(.caption).foregroundStyle(AppColors.secondaryText)
            if let filename {
                Label(filename, systemImage: "paperclip").font(.subheadline)
                Button("Remove attachment", role: .destructive, action: clearAttachment)
            }
        }
    }

    private func submissionCard(_ submission: DocumentSubmission) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Label("Submitted", systemImage: "checkmark.circle.fill").foregroundStyle(AppColors.success)
            if let entitlement = model.entitlement(for: submission) { rewardRow(entitlement) }
            if !submission.registrationNumber.isEmpty {
                Text(submission.registrationNumber).font(.subheadline).textSelection(.enabled)
            }
            if let council = submission.councilName, !council.isEmpty { Text(council).font(.subheadline) }
            if kind == .council, let expiry = submission.validTo, DogBirthday.date(from: expiry) != nil {
                Text("Valid through \(DogBirthday.display(expiry))").font(.subheadline)
            }
            if needsExpiry, submission.rewardStatus == .collected {
                Text("Expiry updated. No additional points awarded.").font(.footnote).foregroundStyle(AppColors.secondaryText)
            }
            if let date = submission.eventDate { Text(DogBirthday.display(date)).font(.subheadline) }
            if submission.fileURL != nil {
                Button { Task { await open(submission) } } label: {
                    Label("View attachment", systemImage: "doc.text.magnifyingglass")
                }.disabled(isDownloading)
            }
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
    }

    @ViewBuilder
    private func rewardRow(_ entitlement: DocumentEntitlement) -> some View {
        if model.isCollected(entitlement) {
            Text("Collected · \(entitlement.rewardPoints) points").foregroundStyle(AppColors.secondaryText)
        } else if entitlement.canCollect {
            PrimaryButton(title: "Collect \(entitlement.rewardPoints) points",
                          isLoading: model.collectingID == entitlement.id,
                          isDisabled: !model.canCollect(entitlement)) {
                Task {
                    if await model.collect(entitlement), model.isActive, isVisible { await onSubmitted() }
                }
            }
        } else {
            Text("Reward unavailable").foregroundStyle(AppColors.secondaryText)
        }
    }

    private func submit() async {
        validationMessage = nil
        guard model.dashboard?.dogs.contains(where: { $0.id == dogID }) == true else {
            validationMessage = "This dog is no longer available. Refresh your Quests."
            return
        }
        do {
            guard kind == .vet || (!review.isReading && review.isConfirmed) else { throw DocumentInputError.confirmationRequired }
            let draft: DocumentDraft
            if kind == .vet {
                guard let fileData, let filename else { throw DocumentInputError.attachmentRequired }
                draft = DocumentDraft(dogID: dogID, kind: kind, registrationNumber: "",
                                      eventDate: DogBirthday.string(from: eventDate), filename: filename, fileData: fileData)
            } else {
                draft = try DocumentDraft.registration(dogID: dogID, kind: kind, method: method,
                    number: review.registrationNumber, councilName: review.councilName, validTo: review.expiryText,
                    registryName: review.registryName, documentDogName: review.dogName,
                    filename: filename, fileData: fileData, expectedEntitlementID: expectedEntitlementID,
                    needsExpiry: needsExpiry, documentReading: review.readingAudit)
            }
            if await model.submit(draft), model.isActive, isVisible {
                isEditing = false
                clearAttachment()
                if kind == .council, let expiry = model.receipt?.submission.validTo,
                   !DocumentRegistration.isCurrent(expiry) {
                    validationMessage = "Expiry updated. This document has expired. Close this page and open the refreshed Quest with renewed registration proof."
                }
                await onChanged()
            }
        } catch { validationMessage = error.localizedDescription }
    }

    private func importFile(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 4 * 1024 * 1024 {
            throw DocumentFileError.tooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 4 * 1024 * 1024 else { throw DocumentFileError.tooLarge }
        if !data.starts(with: Data("%PDF-".utf8)) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_000_000 / height else {
                throw DocumentFileError.invalidFile
            }
        }
        clearAttachment()
        fileData = data
        filename = String(url.lastPathComponent.prefix(150))
        validationMessage = nil
        startReading()
    }

    private func importPhoto(_ item: PhotosPickerItem, generation: UUID) async {
        do {
            guard let original = try await item.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(original as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2000
                  ] as CFDictionary), let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.9)
            else { throw DocumentFileError.invalidFile }
            guard data.count <= 4 * 1024 * 1024 else { throw DocumentFileError.tooLarge }
            guard attachmentGeneration == generation, model.isActive, !Task.isCancelled,
                  kind == .vet || method == .upload else { return }
            fileData = data
            filename = "\(kind.title).jpg"
            validationMessage = nil
            startReading()
        } catch {
            if attachmentGeneration == generation, model.isActive, !Task.isCancelled {
                validationMessage = error.localizedDescription
            }
        }
    }

    private func startReading() {
        guard kind != .vet, method == .upload, model.isActive, let fileData, let filename else { return }
        let generation = attachmentGeneration
        Task {
            guard model.isActive, method == .upload, attachmentGeneration == generation else { return }
            await review.read(data: fileData, filename: filename, kind: kind)
        }
    }

    private func clearAttachment() {
        review.clear()
        choosingExpiry = false
        attachmentGeneration = UUID()
        fileData = nil
        filename = nil
        photoSelection = nil
    }

    private func open(_ submission: DocumentSubmission) async {
        isDownloading = true
        defer { isDownloading = false }
        do {
            let data = try await model.download(submission)
            guard isVisible, model.isActive, !Task.isCancelled else { return }
            clearPreview()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VitailEvidence-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            previewDirectory = directory
            let url = directory.appendingPathComponent((submission.filename as NSString).lastPathComponent)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            preview = DocumentPreviewFile(url: url)
        } catch {
            clearPreview()
            if model.isActive, isVisible, !(error is CancellationError) { validationMessage = error.localizedDescription }
        }
    }

    private func stop() {
        model.stop()
        clearSensitiveData()
    }

    private func clearSensitiveData() {
        preview = nil
        clearPreview()
        clearAttachment()
        validationMessage = nil
    }

    private func clearPreview() {
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
        previewDirectory = nil
    }
}

private enum DocumentFileError: LocalizedError {
    case tooLarge, invalidFile
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Choose a file up to 4 MB."
        case .invalidFile: return "Choose a readable PDF, JPG or PNG. Images must be no larger than 16 megapixels."
        }
    }
}

private struct DocumentPreviewFile: Identifiable { let id = UUID(); let url: URL }

private struct DocumentPreviewController: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
