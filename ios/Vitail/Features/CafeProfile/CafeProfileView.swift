import SwiftUI

struct CafeProfileView: View {
    @ObservedObject var session: SessionStore
    @StateObject private var model: CafeProfileViewModel

    init(session: SessionStore, service: any CafeProfileServing = CafeProfileService()) {
        self.session = session
        _model = StateObject(wrappedValue: CafeProfileViewModel(service: service))
    }

    var body: some View {
        Group {
            if model.isLoading && !model.hasLoaded {
                LoadingView(message: "Loading café details…")
            } else {
                Form {
                    if model.hasLoaded {
                        Section("Café details") {
                            TextField("Café name", text: $model.name)
                            LabeledContent("Email", value: model.email)
                            TextField("Address", text: $model.address, axis: .vertical)
                                .lineLimit(2...3)
                            TextField("Description", text: $model.description, axis: .vertical)
                                .lineLimit(3...6)
                            TextField("Opening hours", text: $model.openingHours, axis: .vertical)
                                .lineLimit(2...4)
                        }
                        .disabled(model.isSaving)

                        Section {
                            if let message = model.validationMessage {
                                Text(message).font(.footnote).foregroundStyle(AppColors.error)
                            }
                            Button {
                                Task { await model.save(using: session) }
                            } label: {
                                HStack {
                                    Text("Save Café Details")
                                    if model.isSaving { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(!model.canSave)
                        } footer: {
                            Text("Offers and point prices are managed by the Vitail administrator.")
                        }
                    }

                    if let message = model.errorMessage {
                        Section {
                            Text(message).foregroundStyle(AppColors.error)
                            if !model.hasLoaded {
                                Button("Try Again") { Task { await model.load() } }
                            }
                        }
                    }
                    if let message = model.successMessage {
                        Section { Text(message).foregroundStyle(AppColors.brand) }
                    }
                    Section {
                        Button("Log Out", role: .destructive) {
                            Task { await session.logout() }
                        }
                        .disabled(model.isSaving)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppColors.background)
        .task { if !model.hasLoaded { await model.load() } }
    }
}
