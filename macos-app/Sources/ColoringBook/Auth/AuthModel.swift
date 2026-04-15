import Foundation
import SwiftUI
import Combine

/// Holds authentication state + the local user's friend list / pending requests.
/// A single `AuthModel` lives for the whole app; `SessionModel` reads from it
/// when it needs a token or the current user's identity.
@MainActor
final class AuthModel: ObservableObject {
    enum State: Equatable {
        case unauthenticated
        case loading            // restoring token / verifying session
        case authenticated(user: AuthUser, token: String)
    }

    @Published var state: State = .unauthenticated
    @Published var friends: [FriendDTO] = []
    @Published var pendingRequests: [PendingRequestDTO] = []
    @Published var errorMessage: String?
    @Published var busy: Bool = false

    let client: AuthClient
    private var refreshTask: Task<Void, Never>?

    init(base: URL) {
        self.client = AuthClient(base: base)
    }

    // MARK: Lifecycle

    /// On launch, try the stored token; fall back to unauthenticated.
    func bootstrap() async {
        guard case .unauthenticated = state else { return }
        if let token = KeychainStore.loadToken() {
            state = .loading
            do {
                let user = try await client.me(token: token)
                state = .authenticated(user: user, token: token)
                startFriendsRefresh()
            } catch {
                KeychainStore.deleteToken()
                state = .unauthenticated
            }
        }
    }

    func login(username: String, password: String) async {
        await runAuth { try await client.login(username: username, password: password) }
    }

    func signup(username: String, password: String) async {
        await runAuth { try await client.signup(username: username, password: password) }
    }

    func logout() async {
        if case .authenticated(_, let token) = state {
            await client.logout(token: token)
        }
        refreshTask?.cancel()
        refreshTask = nil
        KeychainStore.deleteToken()
        friends = []
        pendingRequests = []
        state = .unauthenticated
    }

    // MARK: Friends

    func refreshFriends() async {
        guard case .authenticated(_, let token) = state else { return }
        async let f = try? client.friends(token: token)
        async let p = try? client.pendingRequests(token: token)
        if let f = await f { friends = f }
        if let p = await p { pendingRequests = p }
    }

    /// Returns a human-readable result string (shown by the Add-Friend sheet).
    func sendFriendRequest(username: String) async -> String {
        guard case .authenticated(_, let token) = state else {
            return "Not signed in."
        }
        do {
            let r = try await client.sendFriendRequest(token: token,
                                                       username: username)
            await refreshFriends()
            return r.status == "accepted"
                ? "You're now friends with \(r.target.displayName)."
                : "Request sent to \(r.target.displayName)."
        } catch let err as APIError {
            return err.message
        } catch {
            return error.localizedDescription
        }
    }

    func accept(_ requesterId: String) async {
        guard case .authenticated(_, let token) = state else { return }
        try? await client.acceptRequest(token: token, requesterId: requesterId)
        await refreshFriends()
    }

    func decline(_ requesterId: String) async {
        guard case .authenticated(_, let token) = state else { return }
        try? await client.declineRequest(token: token, requesterId: requesterId)
        await refreshFriends()
    }

    // MARK: Private

    private func runAuth(_ call: () async throws -> AuthResponse) async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let r = try await call()
            KeychainStore.saveToken(r.token)
            state = .authenticated(user: r.user, token: r.token)
            startFriendsRefresh()
        } catch let err as APIError {
            errorMessage = err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startFriendsRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFriends()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}
