import SwiftUI
import HealthKit
import Combine

@MainActor
final class HealthViewModel: ObservableObject {
    // MARK: - UI state

    @Published var isAuthorized: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Health metrics (today)

    @Published var stepsToday: Double = 0
    @Published var activeEnergyBurnedKcalToday: Double = 0
    @Published var distanceWalkingRunningKmToday: Double = 0
    @Published var exerciseMinutesToday: Double = 0
    @Published var standHoursToday: Int = 0
    @Published var heartRateLatestBpm: Double? = nil
    @Published var workoutsToday: [HealthPayload.WorkoutSummary] = []

    // MARK: - Transport / network

    enum SendTransport: String, CaseIterable, Identifiable {
        case webSocket = "WebSocket"
        case httpPost = "HTTP(S) POST"

        var id: String { rawValue }
    }

    @Published var transport: SendTransport = .webSocket

    /// Для WebSocket: пример `ws://192.168.1.10:8080`
    @Published var webSocketEndpoint: String = "ws://192.168.1.100:8080"

    /// Для HTTP POST: пример `http://192.168.1.10:8080/health`
    @Published var httpEndpoint: String = "http://192.168.1.100:8080/health"

    /// Статус сети (WS/HTTP)
    @Published var connectionStatus: String = "Disconnected"

    // MARK: - Private

    private let healthKitManager = HealthKitManager()
    private let webSocketClient = WebSocketClient()
    private let httpClient = HTTPClient()

    init() {
        webSocketClient.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.connectionStatus = status
            }
        }
    }

    // MARK: - HealthKit

    func requestAuthorization() {
        Task {
            do {
                try await healthKitManager.requestAuthorization()

                // Важно: authorizationStatus(for:) показывает только доступ на запись/share.
                // Для read-доступа HealthKit не сообщает, какие типы пользователь разрешил читать.
                // Поэтому после успешного requestAuthorization разрешаем UI и пробуем читать данные:
                // если пользователь запретил чтение, запросы HealthKit просто вернут пустые значения.
                isAuthorized = true
                errorMessage = nil

                loadTodaySummary()
            } catch {
                isAuthorized = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadTodaySummary() {
        guard isAuthorized else {
            errorMessage = "Сначала нажмите «Запросить доступ к HealthKit»."
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            let now = Date()
            let start = Calendar.current.startOfDay(for: now)
            var warnings: [String] = []

            // Важно: каждый тип HealthKit читаем отдельно.
            // Если пользователь запретил, например, пульс или Stand Hours,
            // это больше не ломает загрузку шагов, калорий и дистанции.
            do {
                self.stepsToday = try await healthKitManager.fetchCumulativeSumToday(
                    for: .stepCount,
                    unit: .count()
                ) ?? 0
            } catch {
                self.stepsToday = 0
                if !isHealthKitNoDataError(error) {
                    warnings.append("Шаги: \(error.localizedDescription)")
                }
            }

            do {
                self.activeEnergyBurnedKcalToday = try await healthKitManager.fetchCumulativeSumToday(
                    for: .activeEnergyBurned,
                    unit: .kilocalorie()
                ) ?? 0
            } catch {
                self.activeEnergyBurnedKcalToday = 0
                if !isHealthKitNoDataError(error) {
                    warnings.append("Активные калории: \(error.localizedDescription)")
                }
            }

            do {
                let meters = try await healthKitManager.fetchCumulativeSumToday(
                    for: .distanceWalkingRunning,
                    unit: .meter()
                ) ?? 0
                self.distanceWalkingRunningKmToday = meters / 1000.0
            } catch {
                self.distanceWalkingRunningKmToday = 0
                if !isHealthKitNoDataError(error) {
                    warnings.append("Дистанция: \(error.localizedDescription)")
                }
            }

            do {
                self.exerciseMinutesToday = try await healthKitManager.fetchCumulativeSumToday(
                    for: .appleExerciseTime,
                    unit: .minute()
                ) ?? 0
            } catch {
                self.exerciseMinutesToday = 0
                if !isHealthKitNoDataError(error) {
                    warnings.append("Exercise: \(error.localizedDescription)")
                }
            }

            do {
                self.standHoursToday = try await healthKitManager.fetchTodayStandHours() ?? 0
            } catch {
                self.standHoursToday = 0
                if !isHealthKitNoDataError(error) {
                    warnings.append("Stand: \(error.localizedDescription)")
                }
            }

            do {
                self.heartRateLatestBpm = try await healthKitManager.fetchLatestQuantitySampleToday(
                    for: .heartRate,
                    unit: HKUnit(from: "count/min")
                )
            } catch {
                self.heartRateLatestBpm = nil
                if !isHealthKitNoDataError(error) {
                    warnings.append("Пульс: \(error.localizedDescription)")
                }
            }

            do {
                let workouts = try await healthKitManager.fetchWorkouts(from: start, to: now, limit: 25)
                self.workoutsToday = workouts.map { HealthPayload.WorkoutSummary(from: $0) }
            } catch {
                self.workoutsToday = []
                if !isHealthKitNoDataError(error) {
                    warnings.append("Тренировки: \(error.localizedDescription)")
                }
            }

            self.isLoading = false

            if warnings.isEmpty {
                self.errorMessage = nil
            } else {
                self.errorMessage = "Часть данных не загрузилась:\n" + warnings.joined(separator: "\n")
            }
        }
    }

    private func isHealthKitNoDataError(_ error: Error) -> Bool {
        if let hkError = error as? HKError, hkError.code == .errorNoData {
            return true
        }

        return error.localizedDescription.localizedCaseInsensitiveContains("No data available")
            || error.localizedDescription.localizedCaseInsensitiveContains("No data avaiable")
            || error.localizedDescription.localizedCaseInsensitiveContains("specified predicate")
    }

    // MARK: - WebSocket

    func connectWebSocket() {
        Task {
            await webSocketClient.connect(to: webSocketEndpoint)
        }
    }

    func disconnectWebSocket() {
        webSocketClient.disconnect()
    }

    // MARK: - Sending

    func sendHealthData() {
        Task {
            do {
                let payload = makePayload()
                let jsonData = try HealthPayload.jsonEncoder.encode(payload)

                switch transport {
                case .webSocket:
                    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                        throw NSError(
                            domain: "Encoding",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Не удалось преобразовать JSON в строку."]
                        )
                    }
                    webSocketClient.send(jsonString)

                case .httpPost:
                    let response = try await httpClient.postJSON(jsonData, to: httpEndpoint)
                    self.connectionStatus = "HTTP \(response.statusCode)"
                }

                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func buildJSONPreview() -> String {
        do {
            let payload = makePayload()
            let jsonData = try HealthPayload.jsonEncoder.encode(payload)
            return String(data: jsonData, encoding: .utf8) ?? ""
        } catch {
            return "{ \"error\": \"\(error.localizedDescription)\" }"
        }
    }

    private func makePayload() -> HealthPayload {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)

        return HealthPayload(
            schemaVersion: 1,
            generatedAt: now,
            periodStart: start,
            periodEnd: now,
            metrics: .init(
                steps: stepsToday,
                activeEnergyBurnedKcal: activeEnergyBurnedKcalToday,
                distanceWalkingRunningKm: distanceWalkingRunningKmToday,
                exerciseMinutes: exerciseMinutesToday,
                standHours: standHoursToday,
                heartRateLatestBpm: heartRateLatestBpm
            ),
            workouts: workoutsToday
        )
    }
}
