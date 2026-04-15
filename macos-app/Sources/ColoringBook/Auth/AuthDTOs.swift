import Foundation

struct AuthUser: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let username: String
    let displayName: String
}

struct AuthResponse: Decodable {
    let token: String
    let user: AuthUser
}

struct MeResponse: Decodable { let user: AuthUser }

struct FriendDTO: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let username: String
    let displayName: String
    let online: Bool
}

struct PendingRequestDTO: Decodable, Identifiable, Equatable, Hashable {
    let requesterId: String
    let username: String
    let displayName: String
    let createdAt: Double
    var id: String { requesterId }
}

struct FriendsResponse: Decodable { let friends: [FriendDTO] }
struct PendingResponse: Decodable { let requests: [PendingRequestDTO] }

struct FriendRequestResult: Decodable {
    let status: String  // "pending" | "accepted"
    let target: AuthUser
}

struct APIErrorEnvelope: Decodable { let error: String }

struct APIError: Error, LocalizedError {
    let message: String
    let statusCode: Int
    var errorDescription: String? { message }
}
