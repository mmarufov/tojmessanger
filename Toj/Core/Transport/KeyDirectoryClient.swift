import Foundation

nonisolated enum KeyDirectoryError: Error {
    case badResponse(Int)
}

/// Publishes/fetches public prekey bundles on the dev relay.
nonisolated struct KeyDirectoryClient: Sendable {
    var base: URL
    var session: URLSession = .shared

    func publish(_ bundle: PreKeyBundlePayload, for user: String) async throws {
        var request = URLRequest(url: base.appending(path: "v1/keys/\(user)"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(bundle)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw KeyDirectoryError.badResponse(status) }
    }

    /// nil = peer hasn't published yet (expected while the other phone is still starting).
    func fetch(for user: String) async throws -> PreKeyBundlePayload? {
        let (data, response) = try await session.data(from: base.appending(path: "v1/keys/\(user)"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 { return nil }
        guard status == 200 else { throw KeyDirectoryError.badResponse(status) }
        return try JSONDecoder().decode(PreKeyBundlePayload.self, from: data)
    }
}
