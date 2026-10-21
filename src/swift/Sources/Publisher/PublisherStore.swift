import Foundation
import SwiftUI
import AppKit
import AVFoundation
import CryptoKit

// MARK: - Catalogue Import State

enum CatalogueImportState: Equatable {
    case idle
    case downloading
    case converting
    case importing
    case completed
    case failed(message: String)
    case alreadyExists(localTrackId: UUID, metadataDiffers: Bool)
}

private let keychainService = "com.majik.musicstudio"
private let keychainAccount = "keycloak_id"
private let accessTokenAccount = "publisher_access_token"
private let refreshTokenAccount = "publisher_refresh_token"
private let tokenExpiryKey = "com.majik.musicstudio.publisher.token_expiry"

@MainActor
final class PublisherStore: ObservableObject {
    @Published var authState: AuthState = .notAuthenticated

    // Account identity decoded from the Keycloak token (for display in
    // Settings and the Publisher footer).
    @Published var accountName: String?
    @Published var accountEmail: String?

    // Keycloak token auth
    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private var tokenExpiry: Date?
    @Published var candidates: [PublishCandidate] = []
    @Published var isPublishing: Bool = false
    @Published var currentPublishingTrackName: String?
    @Published var currentPublishingStep: String?
    @Published var catalogueTracks: [CatalogueTrack] = []
    @Published var catalogueState: CatalogueLoadState = .idle
    @Published var artistProfiles: [ArtistProfile] = []
    @Published var maxArtists: Int = 5
    @Published var selectedProfileId: String?
    @Published var profilesLoaded: Bool = false

    // Catalogue Import
    @Published var importStates: [String: CatalogueImportState] = [:]

    // Dashboard
    @Published var salesSummary: SalesSummary?
    @Published var earningsSummary: EarningsSummary?
    @Published var catalogSummary: CatalogSummary?
    @Published var salesTransactions: [SaleTransaction] = []
    @Published var payoutHistory: [PayoutRecord] = []
    @Published var dashboardLoading: Bool = false

    // Server health
    @Published var serverReachable: Bool = true
    private var healthCheckTimer: Timer?

    // MARK: - Auth

    func loadAuthState() {
        // Load Keycloak access/refresh tokens first — the backend
        // authenticates every publisher RPC with the access token, so
        // whether we are "signed in" depends on the tokens, not on the
        // mere presence of a stored keycloak_id.
        do {
            accessToken = try KeychainStore.get(account: accessTokenAccount, service: keychainService)
            refreshToken = try KeychainStore.get(account: refreshTokenAccount, service: keychainService)
        } catch {
            AppLog.error("Failed to load Keycloak tokens from Keychain: \(error)")
        }

        // Load token expiry from UserDefaults
        let expiryInterval = UserDefaults.standard.double(forKey: tokenExpiryKey)
        if expiryInterval > 0 {
            tokenExpiry = Date(timeIntervalSince1970: expiryInterval)
        }

        var storedKeycloakId: String?
        do {
            storedKeycloakId = try KeychainStore.get(account: keychainAccount, service: keychainService)
        } catch {
            AppLog.error("Failed to load Keycloak ID from Keychain: \(error)")
        }

        guard let keycloakId = storedKeycloakId, !keycloakId.isEmpty else { return }

        // Legacy sessions (signed in before token storage existed) have a
        // keycloak_id but no tokens. Such a session cannot make a single
        // successful bridge call — showing "Connected" for it would be a
        // lie, so clear it and present the sign-in UI instead.
        guard accessToken != nil || refreshToken != nil else {
            AppLog.info("Publisher keychain has keycloak_id but no tokens — clearing stale legacy session")
            clearAuth()
            return
        }

        // Recover a missing expiry from the JWT itself (older builds did
        // not persist expires_in, which left ensureValidToken() blind).
        if tokenExpiry == nil, let token = accessToken,
           let exp = Self.decodeJWTClaims(token)?["exp"] as? Double {
            tokenExpiry = Date(timeIntervalSince1970: exp)
        }

        authState = .authenticated(keycloakId: keycloakId)
        updateAccountInfo()
    }

    func clearAuth() {
        do {
            try KeychainStore.delete(account: keychainAccount, service: keychainService)
        } catch {
            AppLog.error("Failed to delete Keycloak credentials from Keychain: \(error)")
        }
        do {
            try KeychainStore.delete(account: accessTokenAccount, service: keychainService)
            try KeychainStore.delete(account: refreshTokenAccount, service: keychainService)
        } catch {
            AppLog.error("Failed to delete Keycloak tokens from Keychain: \(error)")
        }
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        accountName = nil
        accountEmail = nil
        UserDefaults.standard.removeObject(forKey: tokenExpiryKey)
        authState = .notAuthenticated
    }

    // MARK: - OAuth Login

    private static let keycloakRealm = "https://auth.unicorncommander.ai/realms/uchub"
    private static let clientId = "majiks-studio"
    private static let redirectURI = "majiksstudio://auth/callback"

    /// Stored between startLogin() and handleAuthCallback() to complete the PKCE exchange.
    private var pendingCodeVerifier: String?

    func startLogin() {
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.computeCodeChallenge(verifier: codeVerifier)
        pendingCodeVerifier = codeVerifier

        var components = URLComponents(string: "\(Self.keycloakRealm)/protocol/openid-connect/auth")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authURL = components.url else {
            authState = .failed(message: "Failed to build authorization URL")
            pendingCodeVerifier = nil
            return
        }

        NSWorkspace.shared.open(authURL)
    }

    /// Called from `.onOpenURL` when the `majiksstudio://auth/callback` redirect arrives.
    func handleAuthCallback(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "majiksstudio",
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            authState = .failed(message: "No authorization code received")
            return
        }

        guard let codeVerifier = pendingCodeVerifier else {
            authState = .failed(message: "No pending login session")
            return
        }
        pendingCodeVerifier = nil

        Task { await exchangeCodeForToken(code: code, codeVerifier: codeVerifier) }
    }

    private func exchangeCodeForToken(code: String, codeVerifier: String) async {
        let tokenURL = URL(string: "\(Self.keycloakRealm)/protocol/openid-connect/token")!

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientId,
            "code_verifier": codeVerifier,
        ]
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                authState = .failed(message: "Token exchange failed (HTTP \(statusCode))")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idToken = json["id_token"] as? String else {
                authState = .failed(message: "Invalid token response")
                return
            }

            // Extract Keycloak sub from id_token
            let segments = idToken.split(separator: ".")
            guard segments.count >= 2,
                  let payloadData = Self.base64URLDecode(String(segments[1])),
                  let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let sub = payload["sub"] as? String, !sub.isEmpty else {
                authState = .failed(message: "Failed to extract user ID from token")
                return
            }

            // Store Keycloak sub for display/backward compat
            try KeychainStore.set(sub, account: keychainAccount, service: keychainService)

            // Store access token for bridge API auth
            if let newAccessToken = json["access_token"] as? String, !newAccessToken.isEmpty {
                self.accessToken = newAccessToken
                try? KeychainStore.set(newAccessToken, account: accessTokenAccount, service: keychainService)
            }

            // Store refresh token for token renewal
            if let newRefreshToken = json["refresh_token"] as? String, !newRefreshToken.isEmpty {
                self.refreshToken = newRefreshToken
                try? KeychainStore.set(newRefreshToken, account: refreshTokenAccount, service: keychainService)
            }

            // Compute and store token expiry
            if let expiresIn = json["expires_in"] as? Double {
                let expiry = Date().addingTimeInterval(expiresIn)
                self.tokenExpiry = expiry
                UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: tokenExpiryKey)
            }

            // Account identity for display — prefer the id_token claims we
            // already decoded, fall back to the access token payload.
            accountName = (payload["preferred_username"] as? String) ?? (payload["name"] as? String)
            accountEmail = payload["email"] as? String
            if accountName == nil && accountEmail == nil {
                updateAccountInfo()
            }

            authState = .authenticated(keycloakId: sub)
            AppLog.info("OAuth login successful for Keycloak user: \(sub)")
        } catch {
            authState = .failed(message: "Token exchange failed: \(error.localizedDescription)")
        }
    }

    // MARK: - PKCE Helpers

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func computeCodeChallenge(verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }

    /// Decode the payload claims of a JWT without verifying the signature.
    /// Used only for display (username/email) and expiry recovery — the
    /// server remains the authority on token validity.
    static func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payloadData = base64URLDecode(String(segments[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return payload
    }

    /// Refresh the displayed account identity from the current access token.
    private func updateAccountInfo() {
        guard let token = accessToken, let claims = Self.decodeJWTClaims(token) else { return }
        accountName = (claims["preferred_username"] as? String) ?? (claims["name"] as? String)
        accountEmail = claims["email"] as? String
    }

    // MARK: - Token Refresh

    /// In-flight refresh, shared so concurrent callers (the Publisher tab
    /// fires several fetches at once) await ONE token-endpoint POST instead
    /// of racing the same refresh token. With Keycloak refresh-token
    /// rotation, the losers of that race would get rejected and tear down
    /// the persisted session.
    private var refreshInFlight: Task<Void, Error>?

    /// Refresh the Keycloak access token using the stored refresh token.
    /// Deduplicates concurrent calls onto a single network refresh.
    func refreshAccessToken() async throws {
        if let inFlight = refreshInFlight {
            try await inFlight.value
            return
        }
        let task = Task { try await self.performTokenRefresh() }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        try await task.value
    }

    /// The actual token-endpoint POST. Only ever entered via
    /// refreshAccessToken()'s dedupe wrapper.
    private func performTokenRefresh() async throws {
        guard let currentRefreshToken = refreshToken, !currentRefreshToken.isEmpty else {
            authState = .notAuthenticated
            throw PublishError.notAuthenticated
        }

        let tokenURL = URL(string: "\(Self.keycloakRealm)/protocol/openid-connect/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "grant_type": "refresh_token",
            "client_id": Self.clientId,
            "refresh_token": currentRefreshToken,
        ]
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            // Refresh failed -- user needs to re-authenticate
            authState = .notAuthenticated
            accessToken = nil
            refreshToken = nil
            tokenExpiry = nil
            throw PublishError.tokenExpired
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PublishError.tokenExpired
        }

        if let newAccess = json["access_token"] as? String, !newAccess.isEmpty {
            self.accessToken = newAccess
            try? KeychainStore.set(newAccess, account: accessTokenAccount, service: keychainService)
        }
        if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
            self.refreshToken = newRefresh
            try? KeychainStore.set(newRefresh, account: refreshTokenAccount, service: keychainService)
        }
        if let expiresIn = json["expires_in"] as? Double {
            let expiry = Date().addingTimeInterval(expiresIn)
            self.tokenExpiry = expiry
            UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: tokenExpiryKey)
        }

        updateAccountInfo()
        AppLog.info("Keycloak access token refreshed successfully")
    }

    /// Ensure we have a valid access token, refreshing if needed.
    /// Call this before any bridge API request.
    func ensureValidToken() async {
        // No access token in memory: try to recover the session with the
        // refresh token (e.g. access token was lost or never persisted).
        guard accessToken != nil else {
            if refreshToken != nil {
                do {
                    try await refreshAccessToken()
                } catch {
                    AppLog.error("Token recovery via refresh token failed: \(error)")
                }
            }
            return
        }
        guard let expiry = tokenExpiry else { return }

        // Refresh if token expires within 60 seconds
        if expiry.timeIntervalSinceNow < 60 {
            do {
                try await refreshAccessToken()
            } catch {
                AppLog.error("Token refresh failed: \(error)")
            }
        }
    }

    /// The single source of auth for publisher RPCs.
    ///
    /// Returns the Keycloak user id and a usable access token, refreshing
    /// first when needed. Returns nil — after flipping the UI to the
    /// signed-out state — when there is no usable session, so callers can
    /// simply bail out instead of firing requests that are guaranteed to
    /// come back as "Not authenticated" while the sidebar claims
    /// "Connected".
    func validAuthContext() async -> (keycloakId: String, accessToken: String)? {
        guard case .authenticated(let keycloakId) = authState else { return nil }

        await ensureValidToken()

        // A rejected refresh token flips authState inside refreshAccessToken.
        guard case .authenticated = authState else { return nil }

        // Still no token (no refresh token, or recovery failed): the session
        // is unusable — say so instead of pretending to be connected.
        guard let token = accessToken else {
            AppLog.info("Publisher session has no usable access token — signing out")
            clearAuth()
            ToastManager.shared.show("Your majiks.online session has expired — please sign in again", style: .warning)
            return nil
        }

        return (keycloakId, token)
    }

    // MARK: - Artist Profiles

    func fetchArtistProfiles(backend: BackendViewModel) async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            let result = try await backend.listArtistProfiles(keycloakId: keycloakId, accessToken: accessToken)
            artistProfiles = result.profiles.map { ArtistProfile(from: $0) }
            let serverMax = result.maxArtists
            // Default to 5 if server returns 0 or an unreasonably low value
            maxArtists = serverMax > 0 ? serverMax : 5
            AppLog.debug("[PublisherStore] maxArtists from server: \(serverMax), using: \(maxArtists)")
            profilesLoaded = true

            // Auto-select first profile if none selected
            if selectedProfileId == nil, let first = artistProfiles.first {
                selectedProfileId = first.id
            }
            // Clear selection if selected profile was deleted
            if let selected = selectedProfileId,
               !artistProfiles.contains(where: { $0.id == selected }) {
                selectedProfileId = artistProfiles.first?.id
            }
        } catch {
            handleBridgeError(error)
            AppLog.error("Failed to fetch artist profiles: \(error)")
            ToastManager.shared.show("Failed to load artist profiles", style: .error)
        }
    }

    func createArtistProfile(name: String, backend: BackendViewModel) async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            let profileData = try await backend.createArtistProfile(keycloakId: keycloakId, artistName: name, accessToken: accessToken)
            let newProfile = ArtistProfile(from: profileData)
            artistProfiles.append(newProfile)
            // Auto-select newly created profile
            selectedProfileId = newProfile.id
            ToastManager.shared.show("Profile created: \(name)", style: .success)
        } catch {
            handleBridgeError(error)
            AppLog.error("Failed to create artist profile: \(error)")
            ToastManager.shared.show("Failed to create profile", style: .error)
        }
    }

    func updateArtistProfile(_ profile: ArtistProfile, backend: BackendViewModel) async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            try await backend.updateArtistProfile(
                profileId: profile.id,
                keycloakId: keycloakId,
                artistName: profile.artistName,
                website: profile.website,
                socialLinks: profile.socialLinks,
                accessToken: accessToken
            )
            if let idx = artistProfiles.firstIndex(where: { $0.id == profile.id }) {
                artistProfiles[idx] = profile
            }
            ToastManager.shared.show("Profile updated: \(profile.artistName)", style: .success)
        } catch {
            handleBridgeError(error)
            AppLog.error("Failed to update artist profile: \(error)")
            ToastManager.shared.show("Failed to update profile", style: .error)
        }
    }

    func deleteArtistProfile(_ profile: ArtistProfile, backend: BackendViewModel) async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            try await backend.deleteArtistProfile(profileId: profile.id, keycloakId: keycloakId, accessToken: accessToken)
            artistProfiles.removeAll { $0.id == profile.id }
            if selectedProfileId == profile.id {
                selectedProfileId = artistProfiles.first?.id
            }
            ToastManager.shared.show("Profile deleted: \(profile.artistName)", style: .warning)
        } catch {
            AppLog.error("Failed to delete artist profile: \(error)")
            ToastManager.shared.show("Failed to delete profile", style: .error)
        }
    }

    // MARK: - Candidate Management

    func addCandidates(from tracks: [Track]) {
        let existingIds = Set(candidates.map(\.id))
        let newCandidates = tracks
            .filter { !existingIds.contains($0.id) }
            .map { PublishCandidate(from: $0) }
        candidates.append(contentsOf: newCandidates)
    }

    func removeCandidate(_ candidate: PublishCandidate) {
        candidates.removeAll { $0.id == candidate.id }
    }

    func clearCompleted() {
        candidates.removeAll { $0.status.isPublished }
    }

    func retryFailed() {
        for i in candidates.indices {
            if candidates[i].status.isFailed {
                candidates[i].status = .unpublished
            }
        }
    }

    // MARK: - Publishing

    func publishAll(backend: BackendViewModel, library: LibraryStore) async {
        guard let auth = await validAuthContext() else { return }
        let keycloakId = auth.keycloakId

        isPublishing = true
        defer {
            isPublishing = false
            currentPublishingTrackName = nil
            currentPublishingStep = nil
        }

        for i in candidates.indices {
            guard !candidates[i].status.isPublished,
                  !candidates[i].status.isInProgress,
                  !candidates[i].status.isDuplicateWarning else { continue }

            currentPublishingTrackName = candidates[i].title
            await publishTrack(at: i, keycloakId: keycloakId, backend: backend, library: library)
        }

        if candidates.contains(where: { $0.status.isPublished }) {
            await fetchCatalogue(backend: backend)
        }
    }

    func publishSingle(_ candidate: PublishCandidate, backend: BackendViewModel, library: LibraryStore) async {
        guard let auth = await validAuthContext() else { return }
        let keycloakId = auth.keycloakId
        guard let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { return }

        isPublishing = true
        defer { isPublishing = false }

        await publishTrack(at: index, keycloakId: keycloakId, backend: backend, library: library)

        if candidates[index].status.isPublished {
            await fetchCatalogue(backend: backend)
        }
    }

    func publishAnywaySkippingDuplicateCheck(_ candidate: PublishCandidate, backend: BackendViewModel, library: LibraryStore) async {
        guard let auth = await validAuthContext() else { return }
        let keycloakId = auth.keycloakId
        guard let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { return }

        candidates[index].skipDuplicateCheck = true
        candidates[index].status = .unpublished

        isPublishing = true
        defer { isPublishing = false }

        await publishTrack(at: index, keycloakId: keycloakId, backend: backend, library: library)

        if candidates[index].status.isPublished {
            await fetchCatalogue(backend: backend)
        }
    }

    private func publishTrack(at index: Int, keycloakId: String, backend: BackendViewModel, library: LibraryStore) async {
        let candidate = candidates[index]
        let sourcePath = candidate.sourceTrack.audioURL.path

        // Step 1: Convert WAV -> FLAC + M4A
        currentPublishingStep = "Converting audio..."
        candidates[index].status = .converting(progress: 0.5)

        let convResult: (flacPath: String, m4aPath: String, m4aLowPath: String, sourceSizeMB: Double, flacSizeMB: Double, m4aSizeMB: Double, m4aLowSizeMB: Double)
        do {
            convResult = try await backend.convertAudioForPublish(sourcePath: sourcePath)
            AppLog.info("Converted \(candidate.title): \(convResult.sourceSizeMB)MB -> FLAC \(convResult.flacSizeMB)MB + M4A 256k \(convResult.m4aSizeMB)MB + M4A 128k \(convResult.m4aLowSizeMB)MB")
        } catch {
            candidates[index].status = .failed(message: "Conversion failed: \(error.localizedDescription)")
            return
        }

        // Step 2: Compute audio fingerprint (non-fatal)
        currentPublishingStep = "Computing fingerprint..."
        candidates[index].status = .fingerprinting

        var fingerprint: String?
        do {
            let fpResult = try await backend.computeFingerprint(audioPath: sourcePath)
            fingerprint = fpResult.fingerprint
            if let fp = fingerprint {
                AppLog.info("Fingerprint computed for \(candidate.title): \(fp.prefix(20))...")
            } else if !fpResult.available {
                AppLog.info("fpcalc not available — skipping fingerprint for \(candidate.title)")
            } else {
                AppLog.info("Fingerprint returned nil for \(candidate.title) — continuing without it")
            }
        } catch {
            AppLog.error("Fingerprint failed for \(candidate.title): \(error.localizedDescription) — continuing without it")
        }

        // Step 2b: Check for duplicates on server (non-fatal, skippable)
        if let fp = fingerprint, !candidate.skipDuplicateCheck {
            currentPublishingStep = "Checking for duplicates..."
            candidates[index].status = .checkingDuplicates
            do {
                let matchDicts = try await backend.fingerprintLookup(fingerprint: fp, keycloakId: keycloakId, accessToken: accessToken)
                let matches = matchDicts.map { DuplicateMatch(from: $0) }
                    .filter { $0.similarity >= 0.85 }
                if !matches.isEmpty {
                    AppLog.info("Duplicate check found \(matches.count) match(es) for \(candidate.title)")
                    candidates[index].status = .duplicateWarning(matches: matches)
                    return  // Stop here — user can click "Publish Anyway"
                }
            } catch {
                AppLog.error("Duplicate check failed for \(candidate.title): \(error.localizedDescription) — continuing anyway")
            }
        }

        // Step 3: Upload to publishing server(s)
        currentPublishingStep = "Uploading to server..."
        candidates[index].status = .uploading(progress: 0.5)

        // Encode generation params as JSON string if available
        var genParamsJSON: String?
        if let genParams = candidate.sourceTrack.generationParams {
            if let data = try? JSONEncoder().encode(genParams),
               let str = String(data: data, encoding: .utf8) {
                genParamsJSON = str
            }
        }

        // Read LRC synced lyrics if available
        var lrcContent: String?
        if let lrcURL = candidate.sourceTrack.lrcURL,
           FileManager.default.fileExists(atPath: lrcURL.path) {
            lrcContent = try? String(contentsOf: lrcURL, encoding: .utf8)
        }

        // Resolve artwork — skip for variations without custom art (server inherits from parent)
        let artworkPath: String?
        if candidate.parentTrackId != nil && candidate.sourceTrack.customArtworkFileName == nil {
            artworkPath = nil
        } else {
            artworkPath = resolveArtworkPath(for: candidate, library: library)
        }

        // Resolve album artwork (separate from track artwork)
        var albumArtworkPath: String?
        if candidate.parentTrackId == nil || candidate.sourceTrack.customArtworkFileName != nil {
            if let artist = candidate.sourceTrack.artist, let album = candidate.sourceTrack.album {
                let key = "\(artist)|\(album)"
                if let albumMeta = library.albumMetadata[key],
                   let artworkFile = albumMeta.artworkFileName {
                    let url = FileStore.shared.artworkDirectory.appendingPathComponent(artworkFile)
                    if FileManager.default.fileExists(atPath: url.path) { albumArtworkPath = url.path }
                }
            }
        }

        // Publish to majiks.online (the only currently shipping destination).
        // Multi-destination support was scaffolded but never wired up to the
        // UI, so the dead branches were removed in favor of the working path.
        currentPublishingStep = "Uploading to majiks.online..."
        do {
            let result = try await backend.publishTrack(
                m4aPath: convResult.m4aPath,
                keycloakId: keycloakId,
                title: candidate.title,
                studioTrackId: candidate.id.uuidString,
                artist: candidate.artist,
                genre: candidate.genre,
                album: candidate.album,
                bpm: candidate.bpm,
                musicalKey: candidate.musicalKey,
                lyrics: candidate.lyrics,
                duration: candidate.duration,
                fingerprint: fingerprint,
                generationParams: genParamsJSON,
                artistProfileId: candidate.artistProfileId ?? selectedProfileId,
                artworkPath: artworkPath,
                parentTrackId: candidate.parentTrackId,
                lyricsLrc: lrcContent,
                albumArtworkPath: albumArtworkPath,
                audioPath: convResult.flacPath,
                streamPath: convResult.m4aPath,
                streamLowPath: convResult.m4aLowPath,
                description: candidate.description,
                backstory: candidate.backstory,
                backstoryVisibility: candidate.backstoryVisibility,
                subgenre: candidate.subgenre,
                mood: candidate.mood,
                energy: candidate.energy,
                language: candidate.language,
                isExplicit: candidate.isExplicit,
                tags: candidate.tags,
                credits: Self.encodeCredits(candidate.credits),
                scheduledAt: Self.formatScheduledAt(candidate.scheduledAt),
                isrc: candidate.isrc.isEmpty ? nil : candidate.isrc,
                requestISRC: candidate.isrc.isEmpty && candidate.requestISRC,
                accessToken: accessToken
            )
            // Carry the schedule INTO the status. Without it the queue cannot
            // tell a track that is live from one that is merely accepted, and
            // it reported both as "Published" with the same green tick and the
            // same public link -- for a scheduled track, a link to a page that
            // does not exist yet.
            candidates[index].status = .published(
                trackId: result.trackId, slug: result.slug,
                scheduledAt: candidate.scheduledAt)

            // The publish endpoint DROPS a supplied ISRC — attach it afterwards
            // through the PATCH route, which honours it. See
            // `isrcNeedingFollowUp`.
            if let followUp = Self.isrcNeedingFollowUp(
                candidateISRC: candidate.isrc, returnedISRC: result.isrc) {
                do {
                    try await backend.updatePublishedTrack(
                        trackId: result.trackId,
                        keycloakId: keycloakId,
                        isrc: followUp,
                        accessToken: accessToken
                    )
                    AppLog.info("Attached creator ISRC \(followUp) to published track \(result.trackId)")
                } catch {
                    handleBridgeError(error)
                    AppLog.error("Failed to attach ISRC \(followUp) after publishing \(candidate.title): \(error)")
                    ToastManager.shared.show(
                        "Published \(candidate.title), but its ISRC did not attach — set it from the Catalogue tab",
                        style: .warning)
                }
            }

            // Store server-assigned ISRC in local library and re-tag audio
            if let returnedISRC = result.isrc, !returnedISRC.isEmpty {
                library.updateTrackISRC(candidate.id, isrc: returnedISRC)

                // Re-tag the source audio file with the new ISRC
                let audioPath = candidate.sourceTrack.audioURL.path
                if FileManager.default.fileExists(atPath: audioPath) {
                    do {
                        var tagMetadata: [String: String] = ["isrc": returnedISRC]
                        tagMetadata["title"] = candidate.title
                        if !candidate.artist.isEmpty { tagMetadata["artist"] = candidate.artist }
                        if !candidate.album.isEmpty { tagMetadata["album"] = candidate.album }
                        if !candidate.genre.isEmpty { tagMetadata["genre"] = candidate.genre }
                        if let bpm = candidate.bpm { tagMetadata["bpm"] = String(Int(bpm)) }
                        try await backend.tagAudioMetadata(filePath: audioPath, metadata: tagMetadata)
                        AppLog.info("Re-tagged audio with ISRC \(returnedISRC) for \(candidate.title)")
                    } catch {
                        AppLog.error("Failed to re-tag audio with ISRC: \(error)")
                    }
                }
            }

            AppLog.info("Published \(candidate.title) -> \(result.url)")
            // Say which of the two things happened. "Published" on a track that
            // will not appear for another day sends the owner to the site to
            // look for something that is not there.
            if let scheduledAt = candidate.scheduledAt {
                ToastManager.shared.show(
                    "Scheduled: \(candidate.title) goes live "
                    + "\(Self.scheduleToastFormatter.string(from: scheduledAt)).",
                    style: .success)
            } else {
                ToastManager.shared.show("Published: \(candidate.title)", style: .success)
            }
        } catch {
            handleBridgeError(error)
            candidates[index].status = .failed(message: "Upload failed: \(error.localizedDescription)")
            ToastManager.shared.show("Publish failed: \(candidate.title)", style: .error)
        }
    }

    /// The ISRC that has to be pushed through the PATCH route after a successful
    /// publish, or nil when there is nothing to do.
    ///
    /// `POST /api/studio-bridge/publish` is served by `server-wrapper.js`'s
    /// `handleStudioPublish` (routed at server-wrapper.js:1678), not by the
    /// Next.js route of the same path. That handler parses exactly ONE ISRC
    /// input — `fields["request_isrc"]` (server-wrapper.js:1090). It never reads
    /// `fields["isrc"]`. The app sends `isrc` anyway, so the value is dropped on
    /// the floor.
    ///
    /// Worse, the two halves cancelled each other: the app passes
    /// `requestISRC: candidate.isrc.isEmpty && candidate.requestISRC`, so
    /// carrying an ISRC also SUPPRESSED the platform allocation. A candidate
    /// with an ISRC published with none at all — ours discarded by the server,
    /// the platform's never requested — under a green "Published" toast. That is
    /// the exact shape of `ok: true` on work not done.
    ///
    /// `PATCH /api/studio-bridge/tracks/:id` does honour `isrc`: it validates
    /// the format, checks uniqueness, and stamps `isrc_source = 'creator'`
    /// (server-wrapper.js:535-547). So the cure is a follow-up call, entirely on
    /// the client, with no server change.
    nonisolated static func isrcNeedingFollowUp(candidateISRC: String, returnedISRC: String?) -> String? {
        let ours = candidateISRC.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ours.isEmpty else { return nil }
        // The server already has one — either it just allocated it, or the
        // upsert preserved a code from a previous publish (`isrc` is absent from
        // the ON CONFLICT DO UPDATE set at server-wrapper.js:1239). Never
        // overwrite a live, possibly-registered code with a local copy.
        if let returned = returnedISRC?.trimmingCharacters(in: .whitespacesAndNewlines),
           !returned.isEmpty {
            return nil
        }
        return ours
    }

    private static func encodeCredits(_ credits: [Credit]) -> String? {
        guard !credits.isEmpty,
              let data = try? JSONEncoder().encode(credits),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private static func formatScheduledAt(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The schedule as a PERSON reads it, for the toast. `formatScheduledAt`
    /// above is the wire format the server wants and is unreadable out loud;
    /// this is the one that goes in front of the owner.
    private static let scheduleToastFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Catalogue

    func fetchCatalogue(backend: BackendViewModel, library: LibraryStore? = nil) async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        catalogueState = .loading
        do {
            let result = try await backend.fetchCatalogue(keycloakId: keycloakId, accessToken: accessToken)
            catalogueTracks = result.tracks.map { CatalogueTrack(from: $0) }
            catalogueState = .loaded(totalCount: result.total)

            // Pre-populate import states for tracks that already exist locally
            if let library {
                for track in catalogueTracks {
                    guard !track.studioTrackId.isEmpty,
                          let localId = UUID(uuidString: track.studioTrackId),
                          let localTrack = library.tracks.first(where: { $0.id == localId }) else {
                        continue
                    }
                    let differs = doesMetadataDiffer(track, local: localTrack)
                    importStates[track.trackId] = .alreadyExists(localTrackId: localId, metadataDiffers: differs)
                }
            }
        } catch {
            catalogueState = .failed(message: error.localizedDescription)
        }
    }

    func updateCatalogueTrack(_ track: CatalogueTrack, backend: BackendViewModel) async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            try await backend.updatePublishedTrack(
                trackId: track.trackId,
                keycloakId: keycloakId,
                title: track.title,
                genre: track.genre,
                artist: track.artist,
                album: track.album,
                bpm: track.bpm,
                musicalKey: track.musicalKey,
                lyrics: track.lyrics,
                artistProfileId: track.artistProfileId,
                description: track.description,
                backstory: track.backstory,
                backstoryVisibility: track.backstoryVisibility,
                subgenre: track.subgenre,
                mood: track.mood,
                energy: track.energy,
                language: track.language,
                isExplicit: track.isExplicit,
                tags: track.tags,
                credits: Self.encodeCredits(track.credits),
                isrc: track.isrc.isEmpty ? nil : track.isrc,
                accessToken: accessToken
            )
            // Update local array
            if let idx = catalogueTracks.firstIndex(where: { $0.trackId == track.trackId }) {
                catalogueTracks[idx] = track
            }
        } catch {
            handleBridgeError(error)
            AppLog.error("Failed to update catalogue track: \(error)")
            ToastManager.shared.show("Failed to update track metadata", style: .error)
        }
    }

    func unpublishCatalogueTrack(_ track: CatalogueTrack, backend: BackendViewModel) async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            try await backend.unpublishTrack(trackId: track.trackId, keycloakId: keycloakId, accessToken: accessToken)
            catalogueTracks.removeAll { $0.trackId == track.trackId }
            // Update total count
            if case .loaded(let total) = catalogueState {
                catalogueState = .loaded(totalCount: max(0, total - 1))
            }
            ToastManager.shared.show("Unpublished: \(track.title)", style: .warning)
        } catch {
            AppLog.error("Failed to unpublish track: \(error)")
            ToastManager.shared.show("Unpublish failed: \(track.title)", style: .error)
        }
    }

    // MARK: - Catalogue Import

    /// Would importing a row in this state add a track the library already has?
    ///
    /// `LibraryStore.addTrack` is `tracks.insert(track, at: 0)` with no dedupe,
    /// and `importCatalogueTrack` reuses the server's `studioTrackId` as the
    /// Track UUID. So a second import of the same row inserts a SECOND Track
    /// carrying an id that is already present — after which every
    /// `firstIndex(where: { $0.id == ... })` in the app sees only one of the
    /// two, `updateTrack` edits one and leaves the other stale, and
    /// `removeTrack` deletes both rows but only one of the two audio files.
    ///
    /// The per-row Import button never allowed this: it renders a checkmark
    /// instead of a button once the row is `.alreadyExists` or `.completed`.
    /// "Import Selected" (CatalogueView.swift:416) does not consult per-row
    /// state at all, so Select All → Import Selected re-imported every row that
    /// was already local. The in-flight states are included for the same reason:
    /// clicking "Import Selected" twice would otherwise land the same track
    /// twice.
    nonisolated static func importWouldDuplicate(_ state: CatalogueImportState?) -> Bool {
        switch state {
        case .alreadyExists, .completed, .downloading, .converting, .importing:
            return true
        case .none, .idle, .failed:
            // `.failed` must stay retryable — that is what the row's retry
            // button is for.
            return false
        }
    }

    /// Where a catalogue import writes downloaded cover art.
    ///
    /// Deliberately a FIXED path per server track id — which makes this the one
    /// artwork writer in the app that overwrites in place. Every `LibraryStore`
    /// setter mints a fresh `track-<uuid>.jpg` / `album-<uuid>.jpg` instead, and
    /// `ArtworkDecodeCache`'s header records that as the reason the cache is
    /// safe. It is not safe here, so the caller must evict this path before
    /// writing.
    nonisolated static func importedArtworkURL(trackId: String) -> URL {
        FileStore.shared.artworkDirectory.appendingPathComponent("catalogue-\(trackId).jpg")
    }

    /// Write imported cover art, evicting the decode cache for that path FIRST.
    ///
    /// The eviction is the whole point of this function existing rather than the
    /// import calling `data.write(to:)` inline: `ArtworkDecodeCache` is keyed by
    /// path and has no way to notice that the bytes under a path it already
    /// decoded have changed. Skip this and a re-import of a row whose cover
    /// changed on majiks.online looks like it did nothing, forever, until the
    /// app is relaunched.
    nonisolated static func writeImportedArtwork(_ data: Data, to url: URL) throws {
        ArtworkDecodeCache.remove(url: url)
        try data.write(to: url)
    }

    /// Import a catalogue track into the local library by downloading its audio and artwork.
    func importCatalogueTrack(_ track: CatalogueTrack, backend: BackendViewModel, library: LibraryStore) async {
        guard !Self.importWouldDuplicate(importStates[track.trackId]) else {
            AppLog.info("Skipping catalogue import of \(track.title) — already in the library, or already importing")
            return
        }
        guard !track.audioUrl.isEmpty, let audioURL = URL(string: track.audioUrl) else {
            importStates[track.trackId] = .failed(message: "No audio URL available")
            return
        }

        // Step 1: Download M4A
        importStates[track.trackId] = .downloading
        let tempM4A: URL
        do {
            let (data, response) = try await URLSession.shared.data(from: audioURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                importStates[track.trackId] = .failed(message: "Download failed (HTTP \(code))")
                return
            }
            tempM4A = FileManager.default.temporaryDirectory
                .appendingPathComponent("catalogue-import-\(track.trackId).m4a")
            try data.write(to: tempM4A)
        } catch {
            importStates[track.trackId] = .failed(message: "Download failed: \(error.localizedDescription)")
            return
        }

        // Step 2: Convert to WAV via backend
        importStates[track.trackId] = .converting
        let wavURL: URL
        do {
            let (url, _) = try await backend.importAudio(filePath: tempM4A.path)
            wavURL = url
            try? FileManager.default.removeItem(at: tempM4A)
        } catch {
            try? FileManager.default.removeItem(at: tempM4A)
            importStates[track.trackId] = .failed(message: "Conversion failed: \(error.localizedDescription)")
            return
        }

        // Step 3: Create Track and add to library
        importStates[track.trackId] = .importing
        let audioFileName = wavURL.lastPathComponent
        let duration = track.duration > 0 ? track.duration : await Self.getAudioDuration(url: wavURL)

        // Use studioTrackId as the Track UUID if valid, otherwise generate new
        let trackUUID: UUID
        if !track.studioTrackId.isEmpty, let parsed = UUID(uuidString: track.studioTrackId) {
            trackUUID = parsed
        } else {
            trackUUID = UUID()
        }

        var newTrack = Track(
            id: trackUUID,
            title: track.title,
            caption: "",
            audioFileName: audioFileName,
            createdAt: track.publishedAt ?? Date(),
            duration: duration
        )
        newTrack.artist = track.artist.isEmpty ? nil : track.artist
        newTrack.genre = track.genre.isEmpty ? nil : track.genre
        newTrack.bpm = Double(track.bpm)
        newTrack.key = track.musicalKey.isEmpty ? nil : track.musicalKey
        newTrack.lyrics = track.lyrics.isEmpty ? nil : track.lyrics

        // Step 4: Download artwork if available
        if !track.artworkUrl.isEmpty, let artworkURL = URL(string: track.artworkUrl) {
            do {
                let (artData, artResp) = try await URLSession.shared.data(from: artworkURL)
                if let httpResp = artResp as? HTTPURLResponse, httpResp.statusCode == 200 {
                    // In-place overwrite: same path, new bytes.
                    let artDest = Self.importedArtworkURL(trackId: track.trackId)
                    try Self.writeImportedArtwork(artData, to: artDest)
                    newTrack.customArtworkFileName = artDest.lastPathComponent
                }
            } catch {
                AppLog.error("Failed to download catalogue artwork for \(track.title): \(error)")
            }
        }

        library.addTrack(newTrack)
        importStates[track.trackId] = .completed
        AppLog.info("Imported catalogue track \(track.title) -> \(audioFileName)")
    }

    /// Update local track metadata from server catalogue values.
    func updateLocalMetadataFromCatalogue(_ catalogueTrack: CatalogueTrack, localTrackId: UUID, library: LibraryStore) {
        guard var localTrack = library.tracks.first(where: { $0.id == localTrackId }) else { return }

        localTrack.title = catalogueTrack.title
        localTrack.artist = catalogueTrack.artist.isEmpty ? nil : catalogueTrack.artist
        localTrack.genre = catalogueTrack.genre.isEmpty ? nil : catalogueTrack.genre
        localTrack.bpm = Double(catalogueTrack.bpm)
        localTrack.key = catalogueTrack.musicalKey.isEmpty ? nil : catalogueTrack.musicalKey
        localTrack.lyrics = catalogueTrack.lyrics.isEmpty ? nil : catalogueTrack.lyrics

        library.updateTrack(localTrack)
        importStates[catalogueTrack.trackId] = .alreadyExists(localTrackId: localTrackId, metadataDiffers: false)
        AppLog.info("Updated local metadata for \(catalogueTrack.title) from catalogue")
    }

    func computeDiffs(localTrack: Track, catalogueTrack: CatalogueTrack) -> [MetadataDiff] {
        func normalized(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        let comparisons: [(fieldName: String, local: String?, server: String?)] = [
            ("title", normalized(localTrack.title), normalized(catalogueTrack.title)),
            ("artist", normalized(localTrack.artist), normalized(catalogueTrack.artist)),
            ("album", normalized(localTrack.album), normalized(catalogueTrack.album)),
            ("genre", normalized(localTrack.genre), normalized(catalogueTrack.genre)),
            ("lyrics", normalized(localTrack.lyrics), normalized(catalogueTrack.lyrics)),
            ("bpm", normalized(localTrack.bpm.map { String(Int($0)) }), normalized(catalogueTrack.bpm)),
            ("key", normalized(localTrack.key), normalized(catalogueTrack.musicalKey)),
            ("mood", normalized(localTrack.mood), normalized(catalogueTrack.mood)),
        ]

        return comparisons.compactMap { comparison in
            if comparison.local == nil, comparison.server == nil {
                return nil
            }
            guard comparison.local != comparison.server else {
                return nil
            }
            return MetadataDiff(
                fieldName: comparison.fieldName,
                localValue: comparison.local ?? "",
                serverValue: comparison.server ?? ""
            )
        }
    }

    func computeSyncAction(localTrack: Track, catalogueTrack: CatalogueTrack) -> SyncAction {
        let diffs = computeDiffs(localTrack: localTrack, catalogueTrack: catalogueTrack)
        guard !diffs.isEmpty else {
            return .inSync
        }
        return .pushToServer(diffs: diffs)
    }

    func pushLocalMetadataToServer(_ localTrack: Track, catalogueTrack: CatalogueTrack, backend: BackendViewModel) async {
        var updatedTrack = catalogueTrack
        updatedTrack.title = localTrack.title
        updatedTrack.artist = localTrack.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updatedTrack.album = localTrack.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updatedTrack.genre = localTrack.genre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updatedTrack.lyrics = localTrack.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updatedTrack.bpm = localTrack.bpm.map { String(Int($0)) } ?? ""
        updatedTrack.musicalKey = localTrack.key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updatedTrack.mood = localTrack.mood?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let localCredits = localTrack.credits {
            updatedTrack.credits = localCredits
        }

        await updateCatalogueTrack(updatedTrack, backend: backend)
    }

    /// Batch sync: iterate all published tracks, compute diffs, apply in specified direction.
    func syncAllMetadata(direction: SyncDirection, backend: BackendViewModel, library: LibraryStore) async -> Int {
        var synced = 0
        for catalogueTrack in catalogueTracks {
            guard !catalogueTrack.studioTrackId.isEmpty,
                  let localId = UUID(uuidString: catalogueTrack.studioTrackId),
                  let localTrack = library.tracks.first(where: { $0.id == localId }) else {
                continue
            }

            let diffs = computeDiffs(localTrack: localTrack, catalogueTrack: catalogueTrack)
            guard !diffs.isEmpty else { continue }

            switch direction {
            case .pushToServer:
                await pushLocalMetadataToServer(localTrack, catalogueTrack: catalogueTrack, backend: backend)
                synced += 1
            case .pullToLocal:
                updateLocalMetadataFromCatalogue(catalogueTrack, localTrackId: localId, library: library)
                synced += 1
            }
        }
        return synced
    }

    /// Check whether catalogue metadata differs from local track.
    func doesMetadataDiffer(_ catalogue: CatalogueTrack, local: Track) -> Bool {
        !computeDiffs(localTrack: local, catalogueTrack: catalogue).isEmpty
    }

    private static func getAudioDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        return duration.map { CMTimeGetSeconds($0) } ?? 0
    }

    // MARK: - Dashboard

    func fetchSalesSummary(backend: BackendViewModel, period: String = "month") async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            let result = try await backend.fetchCreatorSales(keycloakId: keycloakId, view: "summary", period: period, accessToken: accessToken)
            salesSummary = SalesSummary(from: result)
        } catch {
            handleBridgeError(error)
            AppLog.error("Failed to fetch sales summary: \(error)")
            ToastManager.shared.show("Failed to load sales data", style: .error)
        }
    }

    func fetchSalesHistory(backend: BackendViewModel, period: String = "month") async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            let result = try await backend.fetchCreatorSales(keycloakId: keycloakId, view: "list", period: period, accessToken: accessToken)
            if case .array(let items)? = result["data"] {
                salesTransactions = items.compactMap { item in
                    if case .object(let dict) = item {
                        return SaleTransaction(from: dict)
                    }
                    return nil
                }
            }
        } catch {
            handleBridgeError(error)
            AppLog.error("Failed to fetch sales history: \(error)")
            ToastManager.shared.show("Failed to load sales history", style: .error)
        }
    }

    func fetchEarnings(backend: BackendViewModel) async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            let result = try await backend.fetchCreatorEarnings(keycloakId: keycloakId, view: "summary", accessToken: accessToken)
            earningsSummary = EarningsSummary(from: result)
        } catch {
            handleBridgeError(error)
            AppLog.error("Failed to fetch earnings: \(error)")
            ToastManager.shared.show("Failed to load earnings", style: .error)
        }
    }

    func fetchPayoutHistory(backend: BackendViewModel) async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            let result = try await backend.fetchCreatorEarnings(keycloakId: keycloakId, view: "payouts", accessToken: accessToken)
            if case .array(let items)? = result["data"] {
                payoutHistory = items.compactMap { item in
                    if case .object(let dict) = item {
                        return PayoutRecord(from: dict)
                    }
                    return nil
                }
            }
        } catch {
            handleBridgeError(error)
            AppLog.error("Failed to fetch payout history: \(error)")
            ToastManager.shared.show("Failed to load payout history", style: .error)
        }
    }

    func fetchCatalogSummary(backend: BackendViewModel) async {
        guard let auth = await validAuthContext() else { return }
        let (keycloakId, accessToken) = auth

        do {
            let result = try await backend.fetchCreatorCatalog(keycloakId: keycloakId, view: "summary", accessToken: accessToken)
            catalogSummary = CatalogSummary(from: result)
        } catch {
            handleBridgeError(error)
            AppLog.error("Failed to fetch catalog summary: \(error)")
            ToastManager.shared.show("Failed to load catalog summary", style: .error)
        }
    }

    func fetchDashboardData(backend: BackendViewModel) async {
        dashboardLoading = true
        async let sales: () = fetchSalesSummary(backend: backend)
        async let earnings: () = fetchEarnings(backend: backend)
        async let catalog: () = fetchCatalogSummary(backend: backend)
        _ = await (sales, earnings, catalog)
        dashboardLoading = false
    }

    // MARK: - Server Health Check

    func startHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkServerHealth()
            }
        }
        Task { await checkServerHealth() }
    }

    func stopHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    /// The health endpoint majiks.online actually serves
    /// (`src/app/api/health/route.ts`).
    ///
    /// It used to be `/api/studio-bridge/health`, which does not exist and never
    /// has: unmatched `/api/studio-bridge/*` paths proxy through to Next.js,
    /// which 404s. Probed live, unauthenticated, on 2026-07-27:
    ///
    ///     GET /api/studio-bridge/health -> 404
    ///     GET /api/health               -> 200 {"status":"ok",...}
    nonisolated static let healthCheckURL = URL(string: "https://majiks.online/api/health")!

    /// Only a 2xx means the server answered the health question.
    ///
    /// The old predicate was `statusCode < 500`, so the 404 above scored as
    /// HEALTHY — permanently, for any host that speaks HTTP at all. That is a
    /// green light on the wrong axis: it measured "something is listening", not
    /// "the service is up", and it could not have gone red if majiks.online had
    /// been replaced by a parked page.
    nonisolated static func isHealthy(statusCode: Int) -> Bool {
        (200...299).contains(statusCode)
    }

    private func checkServerHealth() async {
        var request = URLRequest(url: Self.healthCheckURL, timeoutInterval: 10)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            serverReachable = Self.isHealthy(statusCode: code)
        } catch {
            serverReachable = false
        }
    }

    // MARK: - Error Handling

    /// Does this bridge error mean the SESSION is dead, or only that the server
    /// refused this one action?
    ///
    /// The distinction is not cosmetic: the "dead" answer runs `clearAuth()`,
    /// which DELETES the Keycloak access and refresh tokens from the Keychain.
    /// Getting it wrong costs the user their whole majiks.online session.
    ///
    /// majiks.online's `authenticateBridge` (server-wrapper.js:136) answers 401
    /// for every genuine authentication failure — missing header, invalid token
    /// — and 400/404/503 for the rest. It NEVER returns 403. Every 403 a
    /// studio-bridge caller can receive is therefore an entitlement refusal from
    /// a credential the server ACCEPTED: "Artist profile limit reached"
    /// (server-wrapper.js:252), "Admin access required" (:867), the premium
    /// sample gate in the sounds routes.
    ///
    /// The Python bridge labelled 401 and 403 identically — "Authentication
    /// failed (<code>)" — and the old matcher keyed on that phrase. So a
    /// free-tier user creating one artist profile too many was signed out of
    /// majiks.online and had to redo the whole OAuth dance. A plan cap is a
    /// NORMAL outcome and must leave the session alone.
    nonisolated static func isSessionDead(_ message: String) -> Bool {
        // Checked first, and it wins: an explicit 403 is a permission answer to
        // an accepted credential, whatever words surround it.
        if message.contains("403") { return false }
        return message.contains("401")
            || message.contains("Authentication failed")
            || message.contains("unauthorized")
            || message.contains("Not authenticated")
    }

    /// The decision `handleBridgeError` acts on, exposed separately so it can be
    /// asserted without performing the destructive half. A test must never call
    /// `clearAuth()` — it would sign the developer out of majiks.online for
    /// real.
    func shouldEndSession(for error: Error) -> Bool {
        Self.isSessionDead(error.localizedDescription)
    }

    /// Handle bridge API errors, triggering re-auth on auth failures.
    ///
    /// Matches HTTP auth failures (401/unauthorized) and the backend's RPC-level
    /// -32602 "Not authenticated — sign in via the Publisher tab", which
    /// previously slipped through and left the UI claiming "Connected" while
    /// every section errored. Does NOT match entitlement refusals — see
    /// `isSessionDead`.
    func handleBridgeError(_ error: Error) {
        guard shouldEndSession(for: error) else { return }
        AppLog.info("Bridge auth failed -- clearing session for re-login")
        // Full clear (including Keychain) so the dead session does not
        // resurrect as a fake "Connected" state on next launch.
        clearAuth()
        ToastManager.shared.show("Signed out of majiks.online — please sign in again", style: .warning)
    }

    // MARK: - Library Integration

    /// Set of studioTrackId strings for all published catalogue tracks
    var publishedStudioTrackIds: Set<String> {
        Set(catalogueTracks.compactMap { id in
            id.studioTrackId.isEmpty ? nil : id.studioTrackId
        })
    }

    /// Check if a library track has been published
    func isTrackPublished(_ trackId: UUID) -> Bool {
        publishedStudioTrackIds.contains(trackId.uuidString)
    }

    /// Get the catalogue track matching a library track ID
    func catalogueTrackForLibraryTrack(_ trackId: UUID) -> CatalogueTrack? {
        let idString = trackId.uuidString
        return catalogueTracks.first { $0.studioTrackId == idString }
    }

    // MARK: - Artwork Resolution

    /// Resolve the best artwork path for a track being published.
    /// Priority: track custom artwork > album artwork > artist photo > procedural art fallback
    func resolveArtworkPath(for candidate: PublishCandidate, library: LibraryStore) -> String? {
        let track = candidate.sourceTrack

        // 1. Track's custom artwork
        if let fileName = track.customArtworkFileName {
            let url = FileStore.shared.artworkDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }

        // 2. Album artwork
        if let artist = track.artist, let album = track.album {
            let key = "\(artist)|\(album)"
            if let albumMeta = library.albumMetadata[key],
               let artworkFile = albumMeta.artworkFileName {
                let url = FileStore.shared.artworkDirectory.appendingPathComponent(artworkFile)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url.path
                }
            }
        }

        // 3. Artist photo
        if let artist = track.artist {
            if let artistMeta = library.artistMetadata[artist],
               let photoFile = artistMeta.photoFileName {
                let url = FileStore.shared.artworkDirectory.appendingPathComponent(photoFile)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url.path
                }
            }
        }

        // 4. Procedural art fallback — render AlbumArtGenerator to a temporary JPEG
        if let path = renderProceduralArtwork(for: track.id) {
            return path
        }

        return nil
    }

    /// Render the procedural AlbumArtGenerator art for a track to a temporary JPEG file.
    /// Uses ImageRenderer (macOS 13+) to capture the SwiftUI view as an NSImage,
    /// then writes it as a JPEG to the system temp directory.
    private func renderProceduralArtwork(for trackId: UUID) -> String? {
        let artView = AlbumArtGenerator.generate(for: trackId.uuidString, size: 512)
        let renderer = ImageRenderer(content: artView)
        renderer.scale = 2.0

        guard let nsImage = renderer.nsImage else {
            AppLog.error("Procedural artwork render failed: ImageRenderer returned nil for track \(trackId)")
            return nil
        }

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            AppLog.error("Procedural artwork render failed: JPEG conversion failed for track \(trackId)")
            return nil
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("majiks-art-\(trackId.uuidString).jpg")

        do {
            try jpegData.write(to: tempURL)
            AppLog.info("Rendered procedural artwork for track \(trackId) -> \(tempURL.path)")
            return tempURL.path
        } catch {
            AppLog.error("Procedural artwork render failed: could not write JPEG for track \(trackId): \(error)")
            return nil
        }
    }
}
