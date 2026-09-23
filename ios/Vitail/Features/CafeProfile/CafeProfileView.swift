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
                        Section {
                            AvatarPhotoPicker(url: model.photo, name: model.name,
                                              systemImage: "storefront.fill", photoData: $model.photoData)
                                .padding(.vertical, AppSpacing.medium)
                        }
                        .disabled(model.isSaving)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
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
                        .listRowBackground(AppColors.surface)

                        Section {
                            TextField("Google Maps link", text: $model.googleMapsURL,
                                      prompt: Text("Google Maps link").foregroundStyle(AppColors.secondaryText))
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if let url = URL(string: model.googleMapsURL.isEmpty ? (model.mapsLink ?? "") : model.googleMapsURL),
                               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                Link("Open in Google Maps", destination: url)
                            }
                        } header: {
                            Text("Google Maps")
                        } footer: {
                            Text("Paste a Google Maps share link, or leave it blank to use your café address.")
                        }
                        .disabled(model.isSaving)
                        .listRowBackground(AppColors.surface)

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
                            Text("Manage your menu and point prices in Products.")
                        }
                        .listRowBackground(AppColors.surface)
                    }

                    if let message = model.errorMessage {
                        Section {
                            Text(message).foregroundStyle(AppColors.error)
                            if !model.hasLoaded {
                                Button("Try Again") { Task { await model.load() } }
                            }
                        }
                        .listRowBackground(AppColors.surface)
                    }
                    if let message = model.successMessage {
                        Section { Text(message).foregroundStyle(AppColors.success) }
                            .listRowBackground(AppColors.surface)
                    }
                    AppearanceSettingsSection()
                    Section {
                        Button("Log Out", role: .destructive) {
                            Task { await session.logout() }
                        }
                        .foregroundStyle(AppColors.error)
                        .disabled(model.isSaving)
                    }
                    .listRowBackground(AppColors.surface)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppColors.background)
        .task { if !model.hasLoaded { await model.load() } }
    }
}
