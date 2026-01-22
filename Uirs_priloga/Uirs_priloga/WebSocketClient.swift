import Foundation
import Combine

/// WebSocket-клиент для отправки JSON в десктопное приложение.
///
/// Важно: проект у вас, судя по ошибкам, собирается в **Swift 6 language mode** с
/// жёсткой проверкой конкуррентности. Поэтому:
/// - класс изолирован `@MainActor` (всё состояние для UI обновляется строго на main);
/// - в «фоновых» completion-замыканиях мы не трогаем свойства напрямую, а делаем hop
///   на main actor через `Task { @MainActor in ... }`.
@MainActor
final class WebSocketClient: ObservableObject {
    // MARK: - Published state

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectionStatus: String = "Disconnected"

    /// Колбэк для ViewModel (если не хочется подписываться на @Published).
    var onStatusChange: ((String) -> Void)?

    // MARK: - Private

    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    // MARK: - Public API

    /// Подключиться к WebSocket серверу.
    /// Пример URL: `ws://192.168.1.10:8080`
    func connect(to urlString: String) async {
        guard let url = URL(string: urlString) else {
            updateStatus("Bad URL")
            setConnected(false)
            return
        }

        // Закрываем предыдущее соединение, если было.
        disconnect()

        updateStatus("Connecting…")
        setConnected(false)

        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        // Проверяем соединение через ping: если ping прошёл — считаем, что подключились.
        // (Так надёжнее, чем мгновенно ставить Connected сразу после resume.)
        await withCheckedContinuation { continuation in
            task.sendPing { [weak self] error in
                // completion вызывается не на main actor — прыгаем обратно.
                Task { @MainActor in
                    guard let self else {
                        continuation.resume()
                        return
                    }

                    if let error {
                        self.updateStatus("Connect error: \(error.localizedDescription)")
                        self.setConnected(false)
                        self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                        self.webSocketTask = nil
                        continuation.resume()
                        return
                    }

                    self.setConnected(true)
                    self.updateStatus("Connected")

                    // Стартуем приём входящих сообщений (если сервер что-то возвращает).
                    self.listen()

                    // Стартуем keep-alive ping.
                    self.startPinging()

                    continuation.resume()
                }
            }
        }
    }

    func send(_ message: String) {
        guard let task = webSocketTask else {
            updateStatus("Not connected")
            return
        }

        task.send(.string(message)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.updateStatus("Send error: \(error.localizedDescription)")
            }
        }
    }

    func send(data: Data) {
        guard let task = webSocketTask else {
            updateStatus("Not connected")
            return
        }

        task.send(.data(data)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.updateStatus("Send error: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        pingTask?.cancel()
        pingTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        setConnected(false)
        updateStatus("Disconnected")
    }

    // MARK: - Private helpers

    private func startPinging() {
        pingTask?.cancel()

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                // Пингуем раз в 15 секунд.
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)

                guard let self, let task = self.webSocketTask else { return }

                task.sendPing { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        self?.updateStatus("Ping error: \(error.localizedDescription)")
                        self?.setConnected(false)
                    }
                }
            }
        }
    }

    private func listen() {
        guard let task = webSocketTask else { return }

        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        print("WS received text: \(text)")
                    case .data(let data):
                        print("WS received data: \(data.count) bytes")
                    @unknown default:
                        break
                    }

                case .failure(let error):
                    print("WS receive error: \(error)")
                    self.setConnected(false)
                    self.updateStatus("Disconnected (receive error)")
                    return
                }

                // Продолжаем слушать дальше.
                self.listen()
            }
        }
    }

    private func updateStatus(_ status: String) {
        connectionStatus = status
        onStatusChange?(status)
    }

    private func setConnected(_ connected: Bool) {
        isConnected = connected
    }
}
