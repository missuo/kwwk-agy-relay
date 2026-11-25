import Foundation
import NIOConcurrencyHelpers
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Who a bearer token belongs to.
public struct Identity: Sendable, Hashable {
    /// Stable per-user key (the Google account email).
    public var user: String
    /// Seconds until the token expires, as reported at lookup.
    public var expiresIn: Int
    public init(user: String, expiresIn: Int) {
        self.user = user
        self.expiresIn = expiresIn
    }
}

public protocol IdentityResolver: Sendable {
    func identify(token: String) async throws -> Identity
}

/// Resolves Google OAuth access tokens through Google's tokeninfo endpoint,
/// accepting only tokens issued to the Antigravity CLI's OAuth client (the
/// only ones `agy` can use). Lookups are cached per token until it expires.
public final class GoogleTokenInfoResolver: IdentityResolver {
    /// The installed-app OAuth client `agy` (and kwwk's `agy` login) uses.
    public static let antigravityClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep" + ".apps.googleusercontent.com"

    private let cache = NIOLockedValueBox([String: (identity: Identity, expires: Date)]())
    private let session: URLSession
    private let allowedClientIDs: Set<String>

    public init(session: URLSession = .shared, allowedClientIDs: Set<String> = [GoogleTokenInfoResolver.antigravityClientID]) {
        self.session = session
        self.allowedClientIDs = allowedClientIDs
    }

    public func identify(token: String) async throws -> Identity {
        let key = Transcript.sha256(token)
        let now = Date()
        if let hit = cache.withLockedValue({ $0[key] }), hit.expires > now {
            return Identity(user: hit.identity.user, expiresIn: Int(hit.expires.timeIntervalSince(now)))
        }
        var components = URLComponents(string: "https://oauth2.googleapis.com/tokeninfo")!
        components.queryItems = [URLQueryItem(name: "access_token", value: token)]
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let info = try? JSONValue.decode(data) else {
            throw WireError(status: 401, type: "authentication_error", message: "Google rejected the access token")
        }
        let audience = info["azp"]?.stringValue ?? info["aud"]?.stringValue ?? ""
        guard allowedClientIDs.contains(audience) else {
            throw WireError(status: 401, type: "authentication_error",
                            message: "the access token was not issued to the Antigravity CLI client")
        }
        guard let email = info["email"]?.stringValue, !email.isEmpty else {
            throw WireError(status: 401, type: "authentication_error", message: "the access token carries no email scope")
        }
        let expiresIn = info["expires_in"]?.intValue ?? 3000
        let identity = Identity(user: email.lowercased(), expiresIn: expiresIn)
        cache.withLockedValue { cache in
            cache = cache.filter { $0.value.expires > now }
            cache[key] = (identity, now.addingTimeInterval(TimeInterval(expiresIn)))
        }
        return identity
    }
}

/// Development mode: every caller is one local user and the machine's own
/// signed-in `agy` is used as is (no token files are written).
public struct SystemLoginResolver: IdentityResolver {
    public init() {}
    public func identify(token: String) async throws -> Identity {
        Identity(user: "local", expiresIn: 3600)
    }
}
