import XCTest
@testable import Vitail

final class AuthModelsTests: XCTestCase {
    func testAuthResponseDecodesSnakeCaseContract() throws {
        let json = #"""
        {
          "access": "access-token",
          "refresh": "refresh-token",
          "user": {
            "id": 42,
            "email": "owner@example.com",
            "display_name": "Taylor",
            "role": "OWNER"
          }
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthResponse.self, from: json)

        XCTAssertEqual(response.user.id, 42)
        XCTAssertEqual(response.user.displayName, "Taylor")
        XCTAssertEqual(response.user.role, .owner)
        XCTAssertEqual(response.tokens.refresh, "refresh-token")
    }

    func testOnlyOwnerAndCafeRolesAreSupportedOnMobile() {
        XCTAssertTrue(UserRole.owner.isSupportedOnMobile)
        XCTAssertTrue(UserRole.cafe.isSupportedOnMobile)
        XCTAssertFalse(UserRole.admin.isSupportedOnMobile)
    }

    func testRegisterRequestEncodesDisplayNameAsSnakeCase() throws {
        let request = RegisterRequest(
            email: "owner@example.com",
            password: "example-password",
            displayName: "Taylor"
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(object["display_name"], "Taylor")
        XCTAssertNil(object["displayName"])
    }

    func testAccountTypesMapToExpectedRoles() async {
        await MainActor.run {
            XCTAssertEqual(AuthViewModel.AccountType.dogOwner.role, .owner)
            XCTAssertEqual(AuthViewModel.AccountType.cafeOwner.role, .cafe)
        }
    }

    func testSelectingCafeOwnerForcesSignIn() async {
        await MainActor.run {
            let viewModel = AuthViewModel()
            viewModel.mode = .register

            viewModel.select(.cafeOwner)

            XCTAssertEqual(viewModel.accountType, .cafeOwner)
            XCTAssertEqual(viewModel.mode, .login)
        }
    }

    func testRoleMismatchExplainsHowToRetry() {
        let error = APIError.roleMismatch(expected: .owner, actual: .cafe)

        XCTAssertEqual(
            error.localizedDescription,
            "This is a café account. Choose “I'm a cafe owner” to sign in."
        )
    }
}
