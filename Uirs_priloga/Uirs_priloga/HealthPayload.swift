import Foundation
import HealthKit

/// Единый «снимок» данных, который iPhone отправляет в десктопное приложение.
/// Даты кодируются в ISO-8601.
struct HealthPayload: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let periodStart: Date
    let periodEnd: Date

    let metrics: Metrics
    let workouts: [WorkoutSummary]

    struct Metrics: Codable {
        var steps: Double?
        var activeEnergyBurnedKcal: Double?
        var distanceWalkingRunningKm: Double?
        var exerciseMinutes: Double?
        var standHours: Int?
        var heartRateLatestBpm: Double?
    }

    struct WorkoutSummary: Codable, Identifiable {
        var id: String

        var activityType: String
        var activityTypeId: Int

        var start: Date
        var end: Date
        var durationSec: Double

        var totalEnergyBurnedKcal: Double?
        var totalDistanceKm: Double?

        var source: String?

        init(
            id: String,
            activityType: String,
            activityTypeId: Int,
            start: Date,
            end: Date,
            durationSec: Double,
            totalEnergyBurnedKcal: Double?,
            totalDistanceKm: Double?,
            source: String?
        ) {
            self.id = id
            self.activityType = activityType
            self.activityTypeId = activityTypeId
            self.start = start
            self.end = end
            self.durationSec = durationSec
            self.totalEnergyBurnedKcal = totalEnergyBurnedKcal
            self.totalDistanceKm = totalDistanceKm
            self.source = source
        }

        init(from workout: HKWorkout) {
            self.id = workout.uuid.uuidString
            self.activityType = workout.workoutActivityType.humanReadableName
            self.activityTypeId = Int(workout.workoutActivityType.rawValue)
            self.start = workout.startDate
            self.end = workout.endDate
            self.durationSec = workout.duration

            self.totalEnergyBurnedKcal = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())

            if let distance = workout.totalDistance {
                self.totalDistanceKm = distance.doubleValue(for: .meter()) / 1000.0
            } else {
                self.totalDistanceKm = nil
            }

            self.source = workout.sourceRevision.source.name
        }
    }
}

extension HealthPayload {
    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension HKWorkoutActivityType {
    /// Небольшой «человекочитаемый» набор. Для остального — отдаём rawValue.
    var humanReadableName: String {
        switch self {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .traditionalStrengthTraining: return "strength_training"
        case .functionalStrengthTraining: return "functional_strength"
        case .highIntensityIntervalTraining: return "hiit"
        case .dance: return "dance"
        case .rowing: return "rowing"
        case .elliptical: return "elliptical"
        case .stairClimbing: return "stair_climbing"
        case .other: return "other"
        default:
            return "activity_\(self.rawValue)"
        }
    }
}
