import SwiftUI

struct DogDocumentsView: View {
    let dogID: Int
    let service: any DocumentServing
    let session: SessionStore?
    let onChanged: () async -> Void
    @StateObject private var model: DocumentViewModel

    init(dogID: Int, service: any DocumentServing = DocumentService(), session: SessionStore? = nil,
         onChanged: @escaping () async -> Void = {}) {
        self.dogID = dogID
        self.service = service
        self.session = session
        self.onChanged = onChanged
        _model = StateObject(wrappedValue: DocumentViewModel(service: service, session: session))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                if let dog = model.dashboard?.dogs.first(where: { $0.id == dogID }) {
                    HStack(spacing: AppSpacing.medium) {
                        AvatarView(url: dog.photo, name: dog.name, systemImage: "dog.fill", size: 52)
                        Text(dog.name).font(.title2.bold())
                    }
                    ForEach([DocumentKind.council, .microchip]) { kind in
                        NavigationLink {
                            DocumentSubmissionView(service: service, session: session, initialDogID: dogID,
                                initialKind: kind, manageRegistration: true,
                                onSubmitted: onChanged, onChanged: onChanged)
                        } label: {
                            registrationRow(kind)
                        }.buttonStyle(.plain)
                    }
                } else if model.isLoading {
                    ProgressView("Loading documents…")
                } else if model.dashboard != nil {
                    Text("This dog is no longer available.").foregroundStyle(AppColors.secondaryText)
                }
                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(AppColors.error)
                    Button("Try again") { Task { await model.load() } }
                }
            }
            .padding(AppSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Registration documents")
        .navigationBarTitleDisplayMode(.inline)
        .background(AppColors.background)
        .foregroundStyle(AppColors.primaryText)
        .task { await model.load() }
        .refreshable { await model.load() }
        .disabled(!model.isActive)
    }

    private func registrationRow(_ kind: DocumentKind) -> some View {
        let record = model.registration(dogID: dogID, kind: kind)
        return HStack(spacing: AppSpacing.medium) {
            Image(systemName: kind == .council ? "doc.text" : "cpu")
                .font(.title2).foregroundStyle(AppColors.brand)
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text(kind.title).font(.headline)
                if let submission = record?.submission {
                    Text(submission.registrationNumber).font(.subheadline)
                    if kind == .council {
                        if let expiry = submission.validTo, DogBirthday.date(from: expiry) != nil {
                            Text("\(DocumentRegistration.isCurrent(expiry) ? "Valid through" : "Expired") \(DogBirthday.display(expiry))")
                                .font(.footnote).foregroundStyle(AppColors.secondaryText)
                        } else {
                            Text("Expiry date needed").font(.footnote).foregroundStyle(AppColors.secondaryText)
                        }
                    } else if let registry = submission.registryName, !registry.isEmpty {
                        Text(registry).font(.footnote).foregroundStyle(AppColors.secondaryText)
                    }
                    if record?.canRenew == true {
                        Text("Renewal available").font(.footnote).foregroundStyle(AppColors.brand)
                    }
                } else {
                    Text("Add registration details").font(.subheadline).foregroundStyle(AppColors.secondaryText)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").foregroundStyle(AppColors.secondaryText)
        }
        .padding(AppSpacing.large)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
        .contentShape(Rectangle())
    }
}
