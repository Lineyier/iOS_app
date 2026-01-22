import Foundation
import HealthKit

final class HealthKitManager {
    private let healthStore = HKHealthStore()

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.healthDataNotAvailable
        }

        var readTypes = Set<HKObjectType>()

        // «Здоровье»
        if let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) {
            readTypes.insert(stepType)
        }
        if let distanceType = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
            readTypes.insert(distanceType)
        }
        if let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) {
            readTypes.insert(heartRateType)
        }

        // «Фитнес» (кольца активности)
        if let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            readTypes.insert(activeEnergyType)
        }
        if let exerciseTimeType = HKObjectType.quantityType(forIdentifier: .appleExerciseTime) {
            readTypes.insert(exerciseTimeType)
        }
        if let standHourType = HKObjectType.categoryType(forIdentifier: .appleStandHour) {
            readTypes.insert(standHourType)
        }

        // Тренировки (также приходят из «Фитнес»)
        readTypes.insert(HKObjectType.workoutType())

        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    func authorizationStatus(for type: HKSampleType) -> HKAuthorizationStatus {
        healthStore.authorizationStatus(for: type)
    }

    /// Cумма за сегодня для quantity-типа (шаги, калории, дистанция, минуты и т.п.).
    /// Возвращает `nil`, если тип недоступен на текущей ОС.
    func fetchCumulativeSumToday(for identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Double? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return nil
        }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let value = result?.sumQuantity()?.doubleValue(for: unit) ?? 0
                continuation.resume(returning: value)
            }

            self.healthStore.execute(query)
        }
    }

    /// Последнее значение за сегодня (например, пульс).
    /// Возвращает `nil`, если тип недоступен или данных нет.
    func fetchLatestQuantitySampleToday(for identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Double? {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) as? HKQuantityType else {
            return nil
        }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let sample = samples?.first as? HKQuantitySample
                let value = sample?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }

            self.healthStore.execute(query)
        }
    }

    /// Количество «часов стояния» (Stand ring) за сегодня.
    /// Возвращает `nil`, если тип недоступен.
    func fetchTodayStandHours() async throws -> Int? {
        guard let standType = HKObjectType.categoryType(forIdentifier: .appleStandHour) else {
            return nil
        }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: standType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let standSamples = (samples as? [HKCategorySample]) ?? []
                let stoodRaw = HKCategoryValueAppleStandHour.stood.rawValue
                let count = standSamples.filter { $0.value == stoodRaw }.count
                continuation.resume(returning: count)
            }

            self.healthStore.execute(query)
        }
    }

    /// Тренировки в заданном интервале.
    func fetchWorkouts(from start: Date, to end: Date, limit: Int = 25) async throws -> [HKWorkout] {
        let type = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (samples as? [HKWorkout]) ?? []
                continuation.resume(returning: workouts)
            }

            self.healthStore.execute(query)
        }
    }
}

enum HealthKitError: LocalizedError {
    case healthDataNotAvailable

    var errorDescription: String? {
        switch self {
        case .healthDataNotAvailable:
            return "HealthKit недоступен на этом устройстве (например, на симуляторе)."
        }
    }
}
