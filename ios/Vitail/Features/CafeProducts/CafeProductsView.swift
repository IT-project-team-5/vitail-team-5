import SwiftUI

struct CafeProductsView: View {
    @StateObject private var model: CafeProductsViewModel

    init(service: any CafeProductsServing = CafeProductsService()) {
        _model = StateObject(wrappedValue: CafeProductsViewModel(service: service))
    }

    var body: some View {
        Group {
            if model.isLoading && !model.hasLoaded {
                LoadingView(message: "Loading products…")
            } else if !model.hasLoaded {
                ContentUnavailableView {
                    Label("Could not load products", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(model.errorMessage ?? "Please try again.")
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                }
            } else {
                productsPage
            }
        }
        .background(AppColors.background)
        .tint(AppColors.brand)
        .task { if !model.hasLoaded { await model.load() } }
        .sheet(isPresented: $model.isPresentingEditor) {
            CafeProductEditor(model: model)
        }
    }

    private var productsPage: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Your café menu")
                    .font(.headline)
                Spacer()
                Button(action: model.startAdding) {
                    Label("Add Product", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(model.isLoading)
            }
            .padding(AppSpacing.medium)
            .background(AppColors.surface)

            if let error = model.errorMessage {
                HStack {
                    Text(error).font(.footnote).foregroundStyle(AppColors.error)
                    Spacer()
                    Button("Retry") { Task { await model.load() } }
                        .disabled(model.isLoading)
                }
                .padding(AppSpacing.medium)
            }

            ScrollView {
                if model.products.isEmpty {
                    ContentUnavailableView {
                        Label("No products yet", systemImage: "cup.and.saucer")
                    } description: {
                        Text("Add a product and set its point price so dog owners can redeem it at your café.")
                    } actions: {
                        Button("Add Your First Product", action: model.startAdding)
                    }
                    .padding(.top, AppSpacing.extraLarge)
                } else {
                    LazyVStack(spacing: AppSpacing.medium) {
                        ForEach(model.products) { product in
                            productCard(product)
                        }
                    }
                    .padding(AppSpacing.medium)
                }
            }
            .refreshable { await model.load() }
        }
    }

    private func productCard(_ product: CafeProduct) -> some View {
        Button {
            model.startEditing(product)
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                HStack(alignment: .firstTextBaseline) {
                    Text(product.name).font(.headline)
                    Spacer()
                    Image(systemName: "pencil").foregroundStyle(AppColors.brand)
                }
                if !product.description.isEmpty {
                    Text(product.description)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(3)
                }
                HStack {
                    Text("\(product.pointCost) points")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.brand)
                    Spacer()
                    Label(
                        product.isAvailable ? "Available" : "Unavailable",
                        systemImage: product.isAvailable ? "checkmark.circle.fill" : "pause.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(product.isAvailable ? AppColors.brand : AppColors.secondaryText)
                }
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.card)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit product details, point price and availability")
    }
}

private struct CafeProductEditor: View {
    @ObservedObject var model: CafeProductsViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Product details") {
                    TextField("Product name", text: $model.name)
                    TextField("Description", text: $model.description, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Point price", text: $model.pointCost)
                        .keyboardType(.numberPad)
                }
                .disabled(model.isSaving)

                Section {
                    Toggle("Available to redeem", isOn: $model.isAvailable)
                        .disabled(model.isSaving)
                } footer: {
                    Text("Unavailable products stay in your menu but are hidden from the owner's redemption catalogue.")
                }

                if let message = model.validationMessage {
                    Section { Text(message).font(.footnote).foregroundStyle(AppColors.error) }
                }
                if let message = model.saveErrorMessage {
                    Section {
                        Text(message).foregroundStyle(AppColors.error)
                        Text("Your changes are still here. Tap Save to try again.")
                            .font(.footnote)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.background)
            .navigationTitle(model.editingProductID == nil ? "Add Product" : "Edit Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.isPresentingEditor = false }
                        .disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await model.save() }
                    } label: {
                        if model.isSaving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(!model.canSave)
                }
            }
        }
        .interactiveDismissDisabled(model.isSaving)
    }
}
