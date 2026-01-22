import Foundation

/// Простой HTTP(S) клиент для отправки JSON (POST).
final class HTTPClient {
    struct Response {
        let statusCode: Int
        let body: Data
    }

    func postJSON(_ data: Data, to urlString: String) async throws -> Response {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = data

        let (body, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return Response(statusCode: statusCode, body: body)
    }
}
