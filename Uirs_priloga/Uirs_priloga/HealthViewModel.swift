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

                // Проверяем авторизацию по шагам как «индикатор», что доступ выдан.
                if let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) {
                    isAuthorized = healthKitManager.authorizationStatus(for: stepType) == .sharingAuthorized
                } else {
                    isAuthorized = true
                }

                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadTodaySummary() {
        guard isAuthorized else { return }

        isLoading = true

        Task {
            do {
                let now = Date()
                let start = Calendar.current.startOfDay(for: now)

                async let steps = healthKitManager.fetchCumulativeSumToday(for: .stepCount, unit: .count())
                async let activeEnergy = healthKitManager.fetchCumulativeSumToday(for: .activeEnergyBurned, unit: .kilocalorie())
                async let distanceMeters = healthKitManager.fetchCumulativeSumToday(for: .distanceWalkingRunning, unit: .meter())
                async let exerciseMinutes = healthKitManager.fetchCumulativeSumToday(for: .appleExerciseTime, unit: .minute())
                async let standHours = healthKitManager.fetchTodayStandHours()
                async let heartRate = healthKitManager.fetchLatestQuantitySampleToday(
                    for: .heartRate,
                    unit: HKUnit(from: "count/min")
                )
                async let workouts = healthKitManager.fetchWorkouts(from: start, to: now, limit: 25)

                // Если какой-то тип недоступен на ОС — придёт nil, подставляем 0.
                let stepsValue = try await steps ?? 0
                let energyValue = try await activeEnergy ?? 0
                let distanceValueMeters = try await distanceMeters ?? 0
                let exerciseValue = try await exerciseMinutes ?? 0
                let standValue = try await standHours ?? 0
                let hrValue = try await heartRate
                let workoutsValue = try await workouts

                self.stepsToday = stepsValue
                self.activeEnergyBurnedKcalToday = energyValue
                self.distanceWalkingRunningKmToday = distanceValueMeters / 1000.0
                self.exerciseMinutesToday = exerciseValue
                self.standHoursToday = standValue
                self.heartRateLatestBpm = hrValue
                self.workoutsToday = workoutsValue.map { HealthPayload.WorkoutSummary(from: $0) }

                self.errorMessage = nil
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
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
