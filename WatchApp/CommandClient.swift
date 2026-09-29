import Combine
import Foundation

@MainActor
final class CommandClient: ObservableObject {
    @Published private(set) var status = "Not connected"
    @Published private(set) var busy = false
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func send(_ command: String, endpoint: String, token: String) async {
        guard !busy else { return }
        guard let base = URL(string: endpoint), ["http", "https"].contains(base.scheme ?? ""),
              base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, token.count >= 16 else {
            status = "Enter server URL and token (16+ characters)"
            return
        }
        busy = true
        defer { busy = false }
        var request = URLRequest(url: base.appendingPathComponent("command"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Command(
            id: UUID().uuidString, command: command, timestamp: Date().timeIntervalSince1970))
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else { status = "Server error \(http.statusCode)"; return }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            status = reply.executed ? "Done: \(command)" : "Received (dry run)"
        } catch { status = "Failed: \(error.localizedDescription)" }
    }

    private struct Command: Encodable { let id: String; let command: String; let timestamp: Double }
    private struct Reply: Decodable { let executed: Bool }
}
