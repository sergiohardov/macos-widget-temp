import Foundation

// MARK: - Группы температурных датчиков (M1).

enum Metric: String, CaseIterable {
    case cpu, gpu, battery, storage, enclosure
}

final class Sensors {
    private let smc = SMC.shared

    // Известные ключи Apple Silicon (M1) по группам. Читаем только их.
    private let keys: [Metric: [String]] = [
        .cpu: [
            "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T",
            "Tp0X", "Tp0b", "Tp0f", "Tp0j"
        ],
        .gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0T"],
        .battery: ["TB0T", "TB1T", "TB2T"],
        .storage: ["TH0a", "TH0b", "TH0x"],        // NAND/SSD
        .enclosure: ["Ts0P", "Ts1P"]               // корпус/ambient
    ]

    // Правдоподобный диапазон для работающего чипа.
    private let minPlausible = 10.0
    private let maxPlausible = 110.0
    // Максимальное физичное падение температуры между двумя соседними замерами.
    // Резкие провалы (49→9) — артефакт чтения SMC, а не реальное остывание.
    private let maxDropPerTick = 20.0

    // Последние "хорошие" значения для фильтрации выбросов во времени.
    private var lastValue: [Metric: Double] = [:]

    // История значений за сессию (для спарклайна) и максимум за сессию.
    private let historyLimit = 30
    private var history: [Metric: [Double]] = [:]
    private var sessionMaxValue: [Metric: Double] = [:]

    var isAvailable: Bool { smc.isOpen }

    func history(for metric: Metric) -> [Double] {
        history[metric] ?? []
    }

    func sessionMax(for metric: Metric) -> Double? {
        sessionMaxValue[metric]
    }

    private func record(_ value: Double, for metric: Metric) {
        var values = history[metric] ?? []
        values.append(value)
        if values.count > historyLimit {
            values.removeFirst(values.count - historyLimit)
        }
        history[metric] = values
        sessionMaxValue[metric] = max(sessionMaxValue[metric] ?? value, value)
    }

    // Медиана устойчива к одиночному "битому" датчику (в отличие от среднего).
    private func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // Температура одной группы: медиана по её ключам + отсев нефизичных провалов.
    func temperature(for metric: Metric) -> Double? {
        let values = (keys[metric] ?? [])
            .compactMap { smc.temperature(key: $0) }
            .filter { $0 >= minPlausible && $0 <= maxPlausible }

        guard let value = median(of: values) else {
            return lastValue[metric] // нет валидных чтений — держим предыдущее значение
        }
        // Резкое падение больше порога невозможно из-за тепловой инерции — игнорируем тик.
        if let previous = lastValue[metric], previous - value > maxDropPerTick {
            return previous
        }
        lastValue[metric] = value
        record(value, for: metric)
        return value
    }
}
