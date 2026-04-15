import Foundation

/// HTTP client for /auth/* and /friends/* endpoints. Shares the `SERVER`
/// base URL with the WebSocket layer.
struct AuthClient {
    let base: URL
    private let session: URLSession

    init(base: URL) {
        self.base = base
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: cfg)
    }

    // MARK: Auth

    func signup(username: String, password: String) async throws -> AuthResponse {
        try await post(path: "/auth/signup",
                       body: ["username": username, "password": password])
    }

    func login(username: String, password: String) async throws -> AuthResponse {
        try await post(path: "/auth/login",
                       body: ["username": username, "password": password])
    }

    func logout(token: String) async {
        _ = try? await postVoid(path: "/auth/logout", body: [:], token: token)
    }

    func me(token: String) async throws -> AuthUser {
        let r: MeResponse = try await get(path: "/auth/me", token: token)
        return r.user
    }

    // MARK: Friends

    func searchUsers(token: String, query: String) async throws -> [AuthUser] {
        struct R: Decodable { let users: [AuthUser] }
        let url = base
            .appendingPathComponent("users/search")
            .appendingQueryItems(["q": query])
        let r: R = try await getURL(url: url, token: token)
        return r.users
    }

    func friends(token: String) async throws -> [FriendDTO] {
        let r: FriendsResponse = try await get(path: "/friends", token: token)
        return r.friends
    }

    func pendingRequests(token: String) async throws -> [PendingRequestDTO] {
        let r: PendingResponse = try await get(path: "/friends/requests", token: token)
        return r.requests
    }

    func sendFriendRequest(token: String, username: String)
        async throws -> FriendRequestResult
    {
        try await post(path: "/friends/request",
                       body: ["username": username],
                       token: token)
    }

    func acceptRequest(token: String, requesterId: String) async throws {
        try await postVoid(path: "/friends/accept",
                           body: ["requesterId": requesterId],
                           token: token)
    }

    func declineRequest(token: String, requesterId: String) async throws {
        try await postVoid(path: "/friends/decline",
                           body: ["requesterId": requesterId],
                           token: token)
    }

    // MARK: Plumbing

    private func post<T: Decodable>(
        path: String, body: [String: String], token: String? = nil
    ) async throws -> T {
        let data = try JSONEncoder().encode(body)
        let (respData, response) = try await session.data(
            for: makeRequest(path: path, method: "POST", body: data, token: token)
        )
        try check(response, data: respData)
        return try JSONDecoder().decode(T.self, from: respData)
    }

    private func postVoid(
        path: String, body: [String: String], token: String? = nil
    ) async throws {
        let data = try JSONEncoder().encode(body)
        let (respData, response) = try await session.data(
            for: makeRequest(path: path, method: "POST", body: data, token: token)
        )
        try check(response, data: respData)
    }

    private func get<T: Decodable>(path: String, token: String) async throws -> T {
        let url = base.appendingPathComponent(String(path.drop { $0 == "/" }))
        return try await getURL(url: url, token: token)
    }

    private func getURL<T: Decodable>(url: URL, token: String?) async throws -> T {
        let (data, response) = try await session.data(
            for: makeRequest(url: url, method: "GET", body: nil, token: token)
        )
        try check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeRequest(
        path: String, method: String, body: Data?, token: String?
    ) -> URLRequest {
        let url = base.appendingPathComponent(String(path.drop { $0 == "/" }))
        return makeRequest(url: url, method: method, body: body, token: token)
    }

    private func makeRequest(
        url: URL, method: String, body: Data?, token: String?
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token = token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "Bad server response", statusCode: -1)
        }
        if (200..<300).contains(http.statusCode) { return }
        // Prefer the server's "error" field when present.
        let msg = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?
            .error ?? "HTTP \(http.statusCode)"
        throw APIError(message: msg, statusCode: http.statusCode)
    }
}

private extension URL {
    func appendingQueryItems(_ items: [String: String]) -> URL {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)
        else { return self }
        comps.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url ?? self
    }
}
