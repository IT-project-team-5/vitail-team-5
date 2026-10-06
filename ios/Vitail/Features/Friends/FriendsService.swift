import Foundation

protocol FriendsServing: Sendable {
    func overview() async throws -> SocialOverview
    func search(_ query: String) async throws -> [SocialProfile]
    func sendRequest(publicID: String) async throws
    func respondToRequest(id: Int, accept: Bool) async throws
    func removeFriend(publicID: String) async throws
    func block(publicID: String) async throws
    func unblock(publicID: String) async throws
    func updatePreferences(_ preferences: SocialPreferenceUpdate) async throws -> SocialPreferences
    func map() async throws -> SocialMapSnapshot
    func startWalk(requestID: UUID, startedAt: Date) async throws -> SocialWalkSession
    func reportLocation(sessionID: Int, sample: SocialLocationSample) async throws -> SocialWalkSession
    func setWalkState(sessionID: Int, state: String) async throws -> SocialWalkSession
    func invitations() async throws -> NetWalkInvitations
    func invite(publicID: String) async throws
    func respondToInvitation(id: Int, accept: Bool) async throws
    func endInvitation(id: Int) async throws
}

actor FriendsService: FriendsServing {
    private let apiClient: AuthenticatedAPIClient
    private let base = "/api/social"
    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) { self.apiClient = apiClient }
    func overview() async throws -> SocialOverview { try await apiClient.get("\(base)/overview") }
    func search(_ query: String) async throws -> [SocialProfile] {
        try await apiClient.get("\(base)/users", queryItems: [.init(name: "q", value: query)])
    }
    func sendRequest(publicID: String) async throws {
        let _: SocialRelationship = try await apiClient.post("\(base)/friend-requests", body: PublicIDBody(publicID: publicID))
    }
    func respondToRequest(id: Int, accept: Bool) async throws {
        let _: SocialRelationship = try await apiClient.post("\(base)/friend-requests/\(id)/respond", body: AcceptBody(accept: accept))
    }
    func removeFriend(publicID: String) async throws {
        let _: SocialAcknowledgement = try await apiClient.post("\(base)/friends/\(publicID)/remove", body: EmptyRequestBody())
    }
    func block(publicID: String) async throws {
        let _: SocialAcknowledgement = try await apiClient.post("\(base)/blocks", body: PublicIDBody(publicID: publicID))
    }
    func unblock(publicID: String) async throws {
        let _: SocialAcknowledgement = try await apiClient.post("\(base)/blocks/\(publicID)/remove", body: EmptyRequestBody())
    }
    func updatePreferences(_ preferences: SocialPreferenceUpdate) async throws -> SocialPreferences {
        try await apiClient.patch("\(base)/preferences", body: preferences)
    }
    func map() async throws -> SocialMapSnapshot { try await apiClient.get("\(base)/map") }
    func startWalk(requestID: UUID, startedAt: Date) async throws -> SocialWalkSession {
        try await apiClient.post("\(base)/walk-sessions", body: StartBody(requestID: requestID, startedAt: SocialDate.string(startedAt)))
    }
    func reportLocation(sessionID: Int, sample: SocialLocationSample) async throws -> SocialWalkSession {
        try await apiClient.post("\(base)/walk-sessions/\(sessionID)/location", body: sample)
    }
    func setWalkState(sessionID: Int, state: String) async throws -> SocialWalkSession {
        try await apiClient.post("\(base)/walk-sessions/\(sessionID)/state", body: StateBody(state: state))
    }
    func invitations() async throws -> NetWalkInvitations { try await apiClient.get("\(base)/net-walk-invitations") }
    func invite(publicID: String) async throws {
        let _: NetWalkInvitation = try await apiClient.post("\(base)/net-walk-invitations", body: PublicIDBody(publicID: publicID))
    }
    func respondToInvitation(id: Int, accept: Bool) async throws {
        let _: NetWalkInvitation = try await apiClient.post("\(base)/net-walk-invitations/\(id)/respond", body: AcceptBody(accept: accept))
    }
    func endInvitation(id: Int) async throws {
        let _: NetWalkInvitation = try await apiClient.post("\(base)/net-walk-invitations/\(id)/end", body: EmptyRequestBody())
    }
}

private struct SocialAcknowledgement: Decodable, Sendable {}
private struct PublicIDBody: Encodable, Sendable {
    let publicID: String
    enum CodingKeys: String, CodingKey { case publicID = "public_id" }
}
private struct AcceptBody: Encodable, Sendable { let accept: Bool }
private struct StateBody: Encodable, Sendable { let state: String }
private struct StartBody: Encodable, Sendable {
    let requestID: UUID
    let startedAt: String
    enum CodingKeys: String, CodingKey { case requestID = "request_id", startedAt = "started_at" }
}
