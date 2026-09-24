import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DocumentSubmissionView: View {
    @Environment(\.isPresented) private var isPresented
    @StateObject private var model: DocumentViewModel
    private let initialDogID: Int?
    private let onSubmitted: () async -> Void
    @State private var dogID: Int?
    @State private var kind: DocumentKind = .council
    @State private var registrationNumber = ""
    @State private var eventDate = Date()
    @State private var validFrom = Date()
    @State private var validTo = Date()
    @State private var hasSelectedDates = false
    @State private var importingFile = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var fileData: Data?
    @State private var filename: String?
    @State private var validationMessage: String?
    @State private var preview: DocumentPreviewFile?
    @State private var previewDirectory: URL?
    @State private var isDownloading = false
    @State private var isVisible = true

    init(service: any DocumentServing = DocumentService(), session: SessionStore? = nil,
         initialDogID: Int? = nil,
         onSubmitted: @escaping () async -> Void = {}) {
        _model = StateObject(wrappedValue: DocumentViewModel(service: service, session: session))
        self.initialDogID = initialDogID
        self.onSubmitted = onSubmitted
    }

    var body: some View {
        Form {
            if let dashboard = model.dashboard {
                if dashboard.dogs.isEmpty {
                    Section { Text("Add a dog to your account before submitting documents.") }
                } else {
                    submissionForm(dashboard)
                }
                if let receipt = model.receipt {
                    Section {
                        Label("Submitted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(AppColors.success)
                        Text(receipt.awardedPoints > 0
                             ? "\(receipt.awardedPoints) points added."
                             : "Evidence saved. This reward was already received, so no additional points were added.")
                        Text("Your submission is self-reported and may be checked later.")
                            .font(.footnote).foregroundStyle(AppColors.secondaryText)
                    }
                    .listRowBackground(AppColors.surface)
                }
                if !dashboard.submissions.isEmpty {
                    Section("Your submissions") {
                        ForEach(dashboard.submissions) { submission in
                            submissionRow(submission)
                        }
                    }
                    .listRowBackground(AppColors.surface)
                }
            } else if model.isLoading {
                ProgressView("Loading documents…")
            } else {
                Button("Try Again") { Task { await model.load() } }
            }
            if let message = validationMessage ?? model.errorMessage {
                Section { Text(message).foregroundStyle(AppColors.error) }
                    .listRowBackground(AppColors.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isSubmitting || !model.isActive)
        .task {
            await model.load()
            if dogID == nil {
                dogID = model.dashboard?.dogs.first(where: { $0.id == initialDogID })?.id
                    ?? model.dashboard?.dogs.first?.id
            }
        }
        .onChange(of: kind) { _, _ in
            fileData = nil
            filename = nil
            photoSelection = nil
            registrationNumber = ""
            hasSelectedDates = false
            validationMessage = nil
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.pdf]) { result in
            guard model.isActive else { return }
            do { try importPDF(result.get()) }
            catch { validationMessage = error.localizedDescription }
        }
        .onChange(of: photoSelection) { _, selected in
            guard let selected else { return }
            Task { await importPhoto(selected) }
        }
        .sheet(item: $preview, onDismiss: clearPreview) { file in
            DocumentPreviewController(url: file.url)
                .ignoresSafeArea()
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

    @ViewBuilder
    private func submissionForm(_ dashboard: DocumentDashboard) -> some View {
        Section {
            Picker("Dog", selection: $dogID) {
                ForEach(dashboard.dogs) { dog in Text(dog.name).tag(Optional(dog.id)) }
            }
            Picker("Document", selection: $kind) {
                ForEach(DocumentKind.allCases) { item in Text(item.title).tag(item) }
            }
            Text(kind.guidance).font(.footnote).foregroundStyle(AppColors.secondaryText)
            if let eligibility = dashboard.eligibility.first(where: { $0.dogID == dogID && $0.kind == kind }) {
                Text(eligibility.message).font(.footnote).foregroundStyle(AppColors.secondaryText)
            }
        }
        .listRowBackground(AppColors.surface)

        Section("Evidence") {
            if kind != .vet {
                TextField("Registration number (or attach PDF)", text: $registrationNumber)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button { importingFile = true } label: { Label("Choose PDF", systemImage: "doc.badge.plus") }
            } else {
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Label("Choose check-up photo", systemImage: "photo.badge.plus")
                }
            }
            if let filename, let fileData {
                Label(filename, systemImage: kind == .vet ? "photo" : "doc")
                Text(ByteCountFormatter.string(fromByteCount: Int64(fileData.count), countStyle: .file))
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                Button("Remove attachment", role: .destructive) {
                    self.fileData = nil; self.filename = nil; photoSelection = nil
                }
            }
        }
        .listRowBackground(AppColors.surface)

        if kind != .council {
            Section(kind == .vet ? "Visit date" : "Annual registration period") {
                if kind == .vet {
                    DatePicker("Check-up date", selection: $eventDate, in: ...Date(), displayedComponents: .date)
                } else {
                    DatePicker("Valid from", selection: $validFrom, in: ...Date(), displayedComponents: .date)
                    DatePicker("Valid until", selection: $validTo, displayedComponents: .date)
                    Text("Enter a full annual period covering today. The end date should be the first anniversary or the day before.")
                        .font(.footnote).foregroundStyle(AppColors.secondaryText)
                }
                Toggle("I confirm these dates match my evidence", isOn: $hasSelectedDates)
                    .font(.footnote)
            }
            .environment(\.calendar, DogBirthday.calendar)
            .environment(\.timeZone, DogBirthday.timeZone)
            .listRowBackground(AppColors.surface)
        }
        Section {
            Button {
                Task { await submit() }
            } label: {
                HStack {
                    if model.isSubmitting { ProgressView() }
                    Text(model.isSubmitting ? "Submitting…" : "Submit")
                        .fontWeight(.semibold)
                }.frame(maxWidth: .infinity)
            }
            Text("Eligible submissions receive points immediately. Updated evidence for a reward already received earns no extra points.")
                .font(.footnote).foregroundStyle(AppColors.secondaryText)
        }
        .listRowBackground(AppColors.surface)
    }

    private func submissionRow(_ submission: DocumentSubmission) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(submission.kind.title).font(.headline)
            Text("\(submission.dogName) · Submitted · +\(submission.awardedPoints) points")
                .font(.subheadline).foregroundStyle(AppColors.secondaryText)
            if !submission.registrationNumber.isEmpty { Text(submission.registrationNumber).font(.footnote) }
            if let date = submission.eventDate { Text(DogBirthday.display(date)).font(.footnote) }
            if let start = submission.validFrom, let end = submission.validTo {
                Text("\(DogBirthday.display(start)) – \(DogBirthday.display(end))").font(.footnote)
            }
            if submission.fileURL != nil {
                Button { Task { await open(submission) } } label: {
                    Label("View attachment", systemImage: "doc.text.magnifyingglass")
                }.disabled(isDownloading)
            }
        }
        .padding(.vertical, AppSpacing.small)
    }

    private func submit() async {
        validationMessage = nil
        guard let dogID else { validationMessage = "Choose a dog."; return }
        let number = registrationNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == .vet ? fileData != nil : (!number.isEmpty || fileData != nil) else {
            validationMessage = kind == .vet ? "Choose a check-up photo." : "Enter the registration number or attach a PDF."
            return
        }
        guard kind == .council || hasSelectedDates else { validationMessage = "Confirm the dates shown on your evidence."; return }
        let draft = DocumentDraft(
            dogID: dogID, kind: kind, registrationNumber: kind == .vet ? "" : number,
            eventDate: kind == .vet ? DogBirthday.string(from: eventDate) : nil,
            validFrom: kind == .microchip ? DogBirthday.string(from: validFrom) : nil,
            validTo: kind == .microchip ? DogBirthday.string(from: validTo) : nil,
            filename: filename, fileData: fileData
        )
        if await model.submit(draft), model.isActive, isVisible { await onSubmitted() }
    }

    private func importPDF(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 4 * 1024 * 1024 {
            throw DocumentFileError.tooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 4 * 1024 * 1024 else { throw DocumentFileError.tooLarge }
        guard data.starts(with: Data("%PDF-".utf8)) else { throw DocumentFileError.invalidFile }
        fileData = data
        filename = String(url.lastPathComponent.prefix(150))
        validationMessage = nil
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
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
            guard kind == .vet, model.isActive, !Task.isCancelled else { return }
            fileData = data
            filename = "Vet check-up.jpg"
            validationMessage = nil
        } catch {
            if model.isActive, !Task.isCancelled { validationMessage = error.localizedDescription }
        }
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
            if model.isActive, isVisible, !(error is CancellationError) {
                validationMessage = error.localizedDescription
            }
        }
    }

    private func stop() {
        model.stop()
        clearSensitiveData()
    }

    private func clearSensitiveData() {
        preview = nil
        clearPreview()
        fileData = nil
        filename = nil
        photoSelection = nil
        registrationNumber = ""
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
        case .invalidFile: return "The selected file could not be read. Please choose another."
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
