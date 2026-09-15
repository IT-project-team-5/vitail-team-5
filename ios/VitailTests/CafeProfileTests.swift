import XCTest
@testable import Vitail

final class CafeProfileTests: XCTestCase {
    func testProfileDecodesAndUpdateDoesNotSendReadOnlyEmail() throws {
        let profile = try JSONDecoder().decode(CafeProfile.self, from: Data(#"{"name":"Local Cafe","email":"cafe@example.com","address":"1 Main St","description":"Dog friendly","opening_hours":"Mon–Fri 7–3"}"#.utf8))
        XCTAssertEqual(profile.name, "Local Cafe")
        XCTAssertEqual(profile.openingHours, "Mon–Fri 7–3")
        let data = try JSONEncoder().encode(CafeProfileRequest(
            name: profile.name, address: profile.address,
            description: profile.description, openingHours: profile.openingHours
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["opening_hours"], "Mon–Fri 7–3")
        XCTAssertNil(object["email"])
    }

    @MainActor
    func testProfileRequiresLoadedNonBlankNameAndPreservesOptionalFields() async {
        let model = CafeProfileViewModel(service: CafeProfileStub())
        XCTAssertFalse(model.canSave)
        await model.load()
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.email, "cafe@example.com")
        model.name = "   "
        XCTAssertFalse(model.canSave)
        model.name = String(repeating: "x", count: 101)
        XCTAssertFalse(model.canSave)
        model.name = "New Cafe"
        model.address = ""
        model.openingHours = ""
        XCTAssertTrue(model.canSave)
    }
}

private actor CafeProfileStub: CafeProfileServing {
    func getProfile() async throws -> CafeProfile {
        CafeProfile(name: "Cafe", email: "cafe@example.com", address: "", description: "", openingHours: "")
    }
    func updateProfile(_ request: CafeProfileRequest) async throws -> CafeProfile {
        CafeProfile(
            name: request.name, email: "cafe@example.com", address: request.address,
            description: request.description, openingHours: request.openingHours
        )
    }
}
