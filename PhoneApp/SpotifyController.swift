import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import UIKit

@MainActor
final class SpotifyController: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let redirect = "wizardry-spotify://callback"
    @Published var clientID = UserDefaults.standard.string(forKey:"spotifyClientID") ?? (Bundle.main.object(forInfoDictionaryKey:"SpotifyClientID") as? String ?? "")
    @Published private(set) var status = "Connect Spotify Premium to control your active player"
    @Published private(set) var connected = false
    private var auth: ASWebAuthenticationSession?
    private var accessToken = ""
    private var expiresAt = Date.distantPast
    private var verifier = ""
    private var state = ""
    private var busy = false
    private var retryAfter = Date.distantPast
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 4; c.timeoutIntervalForResource = 5
        return URLSession(configuration:c)
    }()
    override init() {
        super.init(); connected = !PairingKeychain.load(account:"spotifyRefresh").isEmpty
        if connected { status = "Spotify connected · start playback in Spotify first" }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where:\.isKeyWindow) ?? ASPresentationAnchor()
    }
    private func random() -> String {
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { return UUID().uuidString+UUID().uuidString }
        return Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
    func login() {
        let id = clientID.trimmingCharacters(in:.whitespacesAndNewlines)
        guard id.count == 32, id.allSatisfy(\.isHexDigit) else { status = "Enter the public Client ID from your Spotify Developer app"; return }
        verifier = random(); state = random()
        let challenge = Data(SHA256.hash(data:Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        var url = URLComponents(string:"https://accounts.spotify.com/authorize")!
        url.queryItems = ["client_id":id,"response_type":"code","redirect_uri":Self.redirect,"code_challenge_method":"S256","code_challenge":challenge,"state":state,"scope":"user-read-playback-state user-modify-playback-state"].map { URLQueryItem(name:$0.key,value:$0.value) }
        auth = ASWebAuthenticationSession(url:url.url!,callbackURLScheme:"wizardry-spotify") { [weak self] callback,error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.auth = nil }
                guard error == nil, let callback, let parts = URLComponents(url:callback,resolvingAgainstBaseURL:false),
                      parts.queryItems?.first(where:{$0.name == "state"})?.value == self.state,
                      let code = parts.queryItems?.first(where:{$0.name == "code"})?.value else {
                    self.status = "Spotify connection cancelled or authorization failed"; return
                }
                do {
                    try await self.token(["grant_type":"authorization_code","code":code,"redirect_uri":Self.redirect,"client_id":id,"code_verifier":self.verifier])
                    UserDefaults.standard.set(id,forKey:"spotifyClientID")
                    self.status = "Spotify connected · start playback in Spotify first"
                } catch { self.status = error.localizedDescription }
                self.verifier = ""; self.state = ""
            }
        }
        auth?.presentationContextProvider = self
        _ = auth?.start()
    }
    func disconnect() {
        try? PairingKeychain.save("",account:"spotifyRefresh")
        accessToken = ""; connected = false; status = "Spotify disconnected"
    }
    private struct TokenResponse: Decodable { var access_token: String; var refresh_token: String?; var expires_in: Double }
    private func token(_ values: [String:String]) async throws {
        var request = URLRequest(url:URL(string:"https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        var parts = URLComponents(); parts.queryItems = values.map { URLQueryItem(name:$0.key,value:$0.value) }
        request.httpBody = parts.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B").data(using:.utf8)
        let (data,response) = try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MusicError.message("Spotify login expired or app configuration was rejected. Reconnect in Setup.") }
        let result = try JSONDecoder().decode(TokenResponse.self,from:data)
        if let refresh = result.refresh_token { try PairingKeychain.save(refresh,account:"spotifyRefresh") }
        accessToken = result.access_token; expiresAt = Date().addingTimeInterval(result.expires_in-60); connected = true
    }
    private func authorizedRequest(_ path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        if expiresAt <= Date() {
            let refresh = PairingKeychain.load(account:"spotifyRefresh")
            guard !refresh.isEmpty else { throw MusicError.message("Connect Spotify in Setup first") }
            try await token(["grant_type":"refresh_token","refresh_token":refresh,"client_id":UserDefaults.standard.string(forKey:"spotifyClientID") ?? clientID.trimmingCharacters(in:.whitespacesAndNewlines)])
        }
        var request = URLRequest(url:URL(string:"https://api.spotify.com/v1/me/player"+path)!)
        request.httpMethod = method; request.setValue("Bearer "+accessToken,forHTTPHeaderField:"Authorization")
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw MusicError.message("Invalid Spotify response") }
        switch http.statusCode {
        case 200..<300: return (data,http)
        case 401: accessToken = ""; expiresAt = .distantPast; throw MusicError.message("Spotify authorization expired; reconnect and try again")
        case 403: throw MusicError.message("Spotify requires Premium, an allowed user, and an unrestricted playback device")
        case 404: throw MusicError.message("Start a song in Spotify on the device you want to control")
        case 429:
            retryAfter = Date().addingTimeInterval(Double(http.value(forHTTPHeaderField:"Retry-After") ?? "30") ?? 30)
            throw MusicError.message("Spotify rate limit reached. Wait before trying again.")
        default: throw MusicError.message("Spotify returned \(http.statusCode); action was not retried")
        }
    }
    private struct Playback: Decodable {
        struct Device: Decodable { var id: String?; var is_restricted: Bool?; var supports_volume: Bool?; var volume_percent: Int? }
        var is_playing: Bool
        var device: Device
    }
    func perform(_ kind: ActionKind, deadline: Double) async -> ActionResult {
        guard !busy else { return .failure("Spotify is busy") }
        guard Date() >= retryAfter else { return .failure("Wait for Spotify's rate limit to reset") }
        busy = true; defer { busy = false }
        do {
            let (data,response) = try await authorizedRequest("")
            guard response.statusCode != 204, let playback = try? JSONDecoder().decode(Playback.self,from:data),
                  let deviceID = playback.device.id, playback.device.is_restricted != true else { return .failure("Start Spotify playback on an available device first") }
            let target = deviceID.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? ""
            let path: String; let method: String
            switch kind {
            case .spotifyNext: path = "/next?device_id=\(target)"; method = "POST"
            case .spotifyPrevious: path = "/previous?device_id=\(target)"; method = "POST"
            case .spotifyPlayPause: path = "/\(playback.is_playing ? "pause" : "play")?device_id=\(target)"; method = "PUT"
            case .spotifyVolumeUp, .spotifyVolumeDown:
                guard playback.device.supports_volume == true, let volume = playback.device.volume_percent else {
                    return .failure("This Spotify device blocks remote volume. On iPhone use the native slider, Watch Now Playing, or a foreground volume Shortcut.")
                }
                path = "/volume?volume_percent=\(min(100,max(0,volume + (kind == .spotifyVolumeUp ? 6 : -6))))&device_id=\(target)"; method = "PUT"
            default: return .failure("Unsupported Spotify action")
            }
            guard Date().timeIntervalSince1970 <= deadline else { return .failure("Spotify command expired; try again") }
            _ = try await authorizedRequest(path,method:method)
            return .init(outcome:.handedOff,message:"Spotify accepted the playback command")
        } catch { status = error.localizedDescription; return .failure(error.localizedDescription) }
    }
    enum MusicError: LocalizedError { case message(String); var errorDescription: String? { if case let .message(s) = self { return s }; return nil } }
}
