import PhotosUI
import SwiftUI
import UIKit
import ImageIO

struct AvatarView: View {
    let url: String?
    let name: String
    var systemImage = "person.fill"
    var size: CGFloat = 64

    var body: some View {
        AsyncImage(url: resolvedURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    AppColors.brand.opacity(0.10)
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.37, weight: .medium))
                        .foregroundStyle(AppColors.brand)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("\(name) photo")
    }

    private var resolvedURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        return URL(string: url, relativeTo: AppConfiguration.apiBaseURL)?.absoluteURL
    }
}

/// Photo access uses the system picker; only the selected image is shared with Vitail.
struct AvatarPhotoPicker: View {
    let url: String?
    let name: String
    var systemImage = "person.fill"
    @Binding var photoData: Data?
    @State private var selection: PhotosPickerItem?
    @State private var cropImage: UIImage?
    @State private var isCropping = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: AppSpacing.small) {
            PhotosPicker(selection: $selection, matching: .images) {
                VStack(spacing: AppSpacing.small) {
                    if let photoData, let image = UIImage(data: photoData) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 96, height: 96).clipShape(Circle())
                    } else {
                        AvatarView(url: url, name: name, systemImage: systemImage, size: 96)
                    }
                    if isLoading { ProgressView() }
                    else { Text("Choose photo").font(.subheadline.weight(.medium)) }
                }
                .foregroundStyle(AppColors.brand)
            }
            .disabled(isLoading)
            .accessibilityLabel("Choose a photo for \(name)")
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(AppColors.error)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: selection) {
            guard let selection else { return }
            isLoading = true
            errorMessage = nil
            defer { isLoading = false }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self),
                      let image = AvatarImageProcessor.previewImage(from: data) else {
                    throw PhotoUploadError.invalidImage
                }
                try Task.checkCancellation()
                cropImage = image
                isCropping = true
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
        .sheet(isPresented: $isCropping, onDismiss: { selection = nil }) {
            if let cropImage {
                AvatarCropView(image: cropImage) { data in photoData = data }
            }
        }
    }
}

enum AvatarImageProcessor {
    static func previewImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1536
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    static func jpegData(from image: UIImage, zoom: CGFloat = 1, offset: CGSize = .zero,
                         previewSide: CGFloat = 280) -> Data? {
        guard image.size.width > 0, image.size.height > 0, previewSide > 0 else { return nil }
        let side: CGFloat = 512
        let scale = max(side / image.size.width, side / image.size.height) * max(zoom, 1)
        let imageSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let offsetX = min(max(offset.width * side / previewSide, -(imageSize.width - side) / 2), (imageSize.width - side) / 2)
        let offsetY = min(max(offset.height * side / previewSide, -(imageSize.height - side) / 2), (imageSize.height - side) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: CGRect(x: (side - imageSize.width) / 2 + offsetX,
                                  y: (side - imageSize.height) / 2 + offsetY,
                                  width: imageSize.width, height: imageSize.height))
        }.jpegData(compressionQuality: 0.82)
    }
}

private struct AvatarCropView: View {
    let image: UIImage
    let onSave: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var errorMessage: String?
    private let side: CGFloat = 280

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.large) {
                    let imageSize = scaledSize
                    Image(uiImage: image).resizable()
                        .frame(width: imageSize.width, height: imageSize.height)
                        .offset(offset)
                        .frame(width: side, height: side)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                        .gesture(DragGesture().onChanged { value in
                            offset = bounded(CGSize(width: dragStart.width + value.translation.width,
                                                    height: dragStart.height + value.translation.height))
                        }.onEnded { _ in dragStart = offset })
                        .accessibilityLabel("Photo preview")
                    Text("Drag to position your photo.")
                        .foregroundStyle(AppColors.secondaryText)
                    Slider(value: $zoom, in: 1...3) { Text("Zoom") }
                        .accessibilityLabel("Photo zoom")
                        .onChange(of: zoom) { _, _ in offset = bounded(offset); dragStart = offset }
                    Button("Reset position") { zoom = 1; offset = .zero; dragStart = .zero }
                    if let errorMessage { Text(errorMessage).foregroundStyle(AppColors.error) }
                }
                .padding(AppSpacing.large)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.background)
            .navigationTitle("Adjust Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Photo") {
                        guard let data = AvatarImageProcessor.jpegData(from: image, zoom: zoom, offset: offset, previewSide: side) else {
                            errorMessage = PhotoUploadError.invalidImage.localizedDescription
                            return
                        }
                        onSave(data)
                        dismiss()
                    }
                }
            }
        }
    }

    private var scaledSize: CGSize {
        let scale = max(side / image.size.width, side / image.size.height) * zoom
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func bounded(_ offset: CGSize) -> CGSize {
        CGSize(width: min(max(offset.width, -(scaledSize.width - side) / 2), (scaledSize.width - side) / 2),
               height: min(max(offset.height, -(scaledSize.height - side) / 2), (scaledSize.height - side) / 2))
    }
}
