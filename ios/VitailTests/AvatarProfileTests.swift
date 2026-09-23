import SwiftUI
import UIKit
import XCTest
@testable import Vitail

final class AvatarProfileTests: XCTestCase {
    func testPhotoUploadEncodesBase64AndUserDecodesOptionalPhoto() throws {
        let data = Data([0, 1, 2, 255])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PhotoUploadRequest(data: data))) as? [String: String])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(object["image_base64"])), data)
        let user = try JSONDecoder().decode(User.self, from: Data(#"{"id":1,"email":"owner@example.com","display_name":"Owner","role":"OWNER","photo":"https://example.com/photo.jpg"}"#.utf8))
        XCTAssertEqual(user.photo, "https://example.com/photo.jpg")
    }

    @MainActor
    func testAvatarCropAlwaysProducesSmallSquareJPEGAndClampsOutsideDrag() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 600), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        }
        let data = try XCTUnwrap(AvatarImageProcessor.jpegData(from: source, zoom: 2,
                                                              offset: CGSize(width: 10_000, height: -10_000)))
        let output = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(output.size, CGSize(width: 512, height: 512))
        XCTAssertLessThan(data.count, 4 * 1024 * 1024)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        XCTAssertNotNil(AvatarImageProcessor.previewImage(from: data))
        XCTAssertNil(AvatarImageProcessor.previewImage(from: Data("not a photo".utf8)))
    }

    @MainActor
    func testSavingOnlyOwnerPhotoRefreshesSignedInUser() async throws {
        let service = AvatarAuthStub()
        let session = SessionStore(authService: service)
        await session.restore()
        guard case let .signedIn(user) = session.state else { return XCTFail("Expected restored owner") }
        let model = OwnerProfileViewModel(user: user)
        model.photoData = Data([1, 2, 3])
        XCTAssertTrue(model.canSave)
        let saved = await model.save(using: session)
        XCTAssertTrue(saved)
        guard case let .signedIn(updated) = session.state else { return XCTFail("Expected owner") }
        XCTAssertEqual(updated.photo, "https://example.com/owner.jpg")
        XCTAssertNil(model.photoData)
        let uploads = await service.uploads
        XCTAssertEqual(uploads, 1)
    }

    @MainActor
    func testFailedDogPhotoPreservesCreatedProfileForRetryWithoutDuplicate() async throws {
        let service = AvatarDogStub()
        let model = DogViewModel(service: service)
        let request = DogWriteRequest(name: "Milo", breedID: 1, ageMonths: 24, size: .medium, isBrachycephalic: false)
        let firstSave = await model.save(dog: nil, request: request, photoData: Data([1]))
        XCTAssertFalse(firstSave)
        XCTAssertEqual(model.dogs.count, 1)
        let createdDog = try XCTUnwrap(model.lastSavedDog)
        XCTAssertNotNil(model.errorMessage)
        let retry = await model.save(dog: createdDog, request: request, photoData: Data([1]))
        XCTAssertTrue(retry)
        let creates = await service.creates
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(model.dogs.count, 1)
        XCTAssertEqual(model.dogs.first?.photo, "https://example.com/dog.jpg")
    }

    @MainActor
    func testAccountAndCafeProfileAppearanceSnapshots() async throws {
        let session = SessionStore(authService: AvatarAuthStub())
        await session.restore()
        guard case let .signedIn(user) = session.state else { return XCTFail("Expected owner fixture") }
        for dark in [false, true] {
            let mode = dark ? "Dark" : "Light"
            try await snapshot(NavigationStack {
                OwnerProfileView(user: user, session: session, dogService: ProfileDogFixture())
                    .navigationTitle("Vitail").navigationBarTitleDisplayMode(.inline)
            }, name: "Clean-Account-\(mode)", dark: dark)
            try await snapshot(NavigationStack {
                CafeProfileView(session: session, service: ProfileCafeFixture())
                    .navigationTitle("Vitail").navigationBarTitleDisplayMode(.inline)
            }, name: "Clean-Cafe-Profile-\(mode)", dark: dark)
        }
        let dogs = DogViewModel(service: ProfileDogFixture())
        await dogs.load()
        try await snapshot(DogFormView(viewModel: dogs), name: "Clean-New-Dog", dark: false)
    }

    @MainActor
    private func snapshot<Content: View>(_ content: Content, name: String, dark: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content.vitailAppearance().preferredColorScheme(dark ? .dark : .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}

private actor AvatarAuthStub: AuthServing {
    nonisolated let credentialEvents = AsyncStream<CredentialEvent> { _ in }
    private var user = User(id: 1, email: "owner@example.com", displayName: "Owner", role: .owner)
    private(set) var uploads = 0
    func login(email: String, password: String) async throws -> AuthResponse { throw APIError.invalidResponse }
    func register(email: String, password: String, displayName: String) async throws -> AuthResponse { throw APIError.invalidResponse }
    func persist(_ tokens: AuthTokens) async throws {}
    func restoreUser() async throws -> User? { user }
    func clearSession() async throws {}
    func updateProfile(displayName: String) async throws -> User { throw APIError.invalidResponse }
    func uploadPhoto(_ data: Data) async throws -> User {
        uploads += 1
        user.photo = "https://example.com/owner.jpg"
        return user
    }
}

private actor AvatarDogStub: DogServicing {
    private let breed = Breed(id: 1, name: "Mixed", energyLevel: .moderate, defaultSize: .medium, isBrachycephalic: false)
    private(set) var creates = 0
    private var uploads = 0
    func getDogs() async throws -> [Dog] { [] }
    func getBreeds() async throws -> [Breed] { [breed] }
    func createDog(_ request: DogWriteRequest) async throws -> Dog { creates += 1; return dog() }
    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog { dog() }
    func deleteDog(id: Int) async throws {}
    func getGoal(dogID: Int) async throws -> DogGoal { throw APIError.invalidResponse }
    func uploadPhoto(dogID: Int, data: Data) async throws -> Dog {
        uploads += 1
        if uploads == 1 { throw APIError.network("Upload interrupted") }
        var result = dog()
        result.photo = "https://example.com/dog.jpg"
        return result
    }
    private func dog() -> Dog {
        Dog(id: 7, name: "Milo", photo: nil, breed: breed, ageMonths: 24, size: .medium,
            isBrachycephalic: false, createdAt: "2026-09-23T00:00:00Z")
    }
}


private actor ProfileDogFixture: DogServicing {
    private let breed = Breed(id: 1, name: "Golden Retriever", energyLevel: .moderate, defaultSize: .large, isBrachycephalic: false)
    func getDogs() async throws -> [Dog] {
        [Dog(id: 1, name: "Milo", photo: nil, breed: breed, ageMonths: 24, size: .large,
             isBrachycephalic: false, createdAt: "2026-09-23T00:00:00Z"),
         Dog(id: 2, name: "Luna", photo: nil, breed: breed, ageMonths: 38, size: .medium,
             isBrachycephalic: false, createdAt: "2026-09-23T00:00:00Z")]
    }
    func getBreeds() async throws -> [Breed] { [breed] }
    func createDog(_ request: DogWriteRequest) async throws -> Dog { throw APIError.invalidResponse }
    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog { throw APIError.invalidResponse }
    func deleteDog(id: Int) async throws { throw APIError.invalidResponse }
    func getGoal(dogID: Int) async throws -> DogGoal { throw APIError.invalidResponse }
}

private actor ProfileCafeFixture: CafeProfileServing {
    func getProfile() async throws -> CafeProfile {
        CafeProfile(name: "Riverside Paws Café", email: "riverside@example.com", address: "1 Riverside Walk, Melbourne",
                    description: "Coffee and a sunny spot for you and your dog.", openingHours: "Every day · 7 am – 3 pm",
                    googleMapsURL: "", mapsLink: "https://maps.google.com/?q=Melbourne", photo: nil)
    }
    func updateProfile(_ request: CafeProfileRequest) async throws -> CafeProfile { throw APIError.invalidResponse }
}
