import Cocoa
import UserNotifications

// Пороги перегрева.
private let warnThreshold = 80.0       // жёлтый
private let critThreshold = 95.0       // красный + уведомление
private let rearmThreshold = 90.0      // гистерезис: ниже этого уведомление "перевзводится"

enum Severity {
    case normal, warning, critical

    init(temperature: Double) {
        if temperature >= critThreshold { self = .critical }
        else if temperature >= warnThreshold { self = .warning }
        else { self = .normal }
    }

    // Цвет для текста. Для normal — nil (системный labelColor).
    var textColor: NSColor? {
        switch self {
        case .normal: return nil
        case .warning: return .systemYellow
        case .critical: return .systemRed
        }
    }

    // Цвет тинта иконки. Для normal — nil (адаптивный шаблон).
    var iconTint: NSColor? {
        switch self {
        case .normal: return nil
        case .warning: return .systemYellow
        case .critical: return .systemRed
        }
    }

    var thermometerSymbol: String {
        switch self {
        case .normal: return "thermometer.low"
        case .warning: return "thermometer.medium"
        case .critical: return "thermometer.high"
        }
    }
}

// UI-подписи для метрик.
extension Metric {
    var menuTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Батарея"
        case .storage: return "Накопитель"
        case .enclosure: return "Корпус"
        }
    }

    // Короткая метка для компактного отображения в статусбаре.
    var shortLabel: String {
        switch self {
        case .cpu: return "C"
        case .gpu: return "G"
        case .battery: return "B"
        case .storage: return "SSD"
        case .enclosure: return "ENC"
        }
    }

    // Подпись под температурой в статусбаре.
    var barLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "BAT"
        case .storage: return "SSD"
        case .enclosure: return "ENC"
        }
    }

    // Цвет линии на графике истории (отличается от цветов перегрева).
    var graphColor: NSColor {
        switch self {
        case .cpu: return .systemBlue
        case .gpu: return .systemPurple
        case .battery: return .systemGreen
        case .storage: return .systemOrange
        case .enclosure: return .systemTeal
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let sensors = Sensors()
    private var timer: Timer?
    private var refreshInterval: TimeInterval = 2.0
    private var isPaused = false
    private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    // Выбранные для показа метрики (хранятся между запусками).
    private var selectedMetrics: Set<Metric> = []
    private let defaultsKey = "selectedMetrics"

    // Показывать ли график истории в меню.
    private var showHistory = false
    private let historyKey = "showHistory"

    // Метрики, по которым уже отправлено уведомление о перегреве (гистерезис).
    private var activeAlerts: Set<Metric> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSelection()
        requestNotificationAuthorization()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = statusFont
            button.imagePosition = .imageLeading
        }

        // Меню создаётся один раз и наполняется лениво — только в момент открытия.
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        tick()
        startTimer()
        registerSleepObservers()
    }

    // MARK: - Сохранение выбора

    private func loadSelection() {
        let raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        selectedMetrics = Set(raw.compactMap(Metric.init(rawValue:)))
        showHistory = UserDefaults.standard.bool(forKey: historyKey)
    }

    private func saveSelection() {
        UserDefaults.standard.set(selectedMetrics.map(\.rawValue), forKey: defaultsKey)
    }

    // MARK: - Таймер

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Пауза при сне дисплея/системы

    private func registerSleepObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            nc.addObserver(self, selector: #selector(onSleep), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            nc.addObserver(self, selector: #selector(onWake), name: name, object: nil)
        }
    }

    @objc private func onSleep() {
        isPaused = true
        stopTimer()
    }

    @objc private func onWake() {
        guard isPaused else { return }
        isPaused = false
        tick()
        startTimer()
    }

    // MARK: - Тик: читаем 5 групп, обновляем статусбар, проверяем перегрев

    private func tick() {
        guard let button = statusItem.button else { return }

        guard sensors.isAvailable else {
            showIcon(severity: .critical, symbolOverride: "thermometer.medium.slash")
            return
        }

        // Читаем все группы (нужно для иконки-индикатора и уведомлений).
        var temps: [Metric: Double] = [:]
        for metric in Metric.allCases {
            if let value = sensors.temperature(for: metric) {
                temps[metric] = value
            }
        }

        checkOverheat(temps)

        // Ничего не выбрано — иконка, окрашенная по самой горячей зоне.
        if selectedMetrics.isEmpty {
            let hottest = temps.values.max() ?? 0
            showIcon(severity: Severity(temperature: hottest))
            return
        }

        // Иначе — двухстрочные колонки (температура сверху, подпись снизу).
        button.contentTintColor = nil
        button.attributedTitle = NSAttributedString(string: "")
        button.image = makeStatusImage(temps: temps)
        button.imagePosition = .imageOnly
    }

    // Рисует статусбар: для каждой выбранной метрики колонка «47°» / «CPU».
    private func makeStatusImage(temps: [Metric: Double]) -> NSImage {
        let height = NSStatusBar.system.thickness
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .medium)
        let columnSpacing: CGFloat = 8
        let sidePadding: CGFloat = 3

        struct Column {
            let number: NSAttributedString
            let label: NSAttributedString
            let width: CGFloat
        }

        let columns: [Column] = Metric.allCases
            .filter { selectedMetrics.contains($0) }
            .map { metric in
                let value = temps[metric]
                let color = value.flatMap { Severity(temperature: $0).textColor } ?? NSColor.labelColor
                let number = NSAttributedString(
                    string: format(value),
                    attributes: [.font: numberFont, .foregroundColor: color]
                )
                let label = NSAttributedString(
                    string: metric.barLabel,
                    attributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]
                )
                let width = max(number.size().width, label.size().width)
                return Column(number: number, label: label, width: width)
            }

        let totalWidth = columns.reduce(0) { $0 + $1.width }
            + columnSpacing * CGFloat(max(columns.count - 1, 0))
            + sidePadding * 2
        let size = NSSize(width: max(totalWidth, 1), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            var x = sidePadding
            for column in columns {
                let numberSize = column.number.size()
                let labelSize = column.label.size()
                let blockHeight = numberSize.height + labelSize.height
                let startY = (height - blockHeight) / 2
                column.label.draw(at: NSPoint(x: x + (column.width - labelSize.width) / 2, y: startY))
                column.number.draw(at: NSPoint(x: x + (column.width - numberSize.width) / 2, y: startY + labelSize.height))
                x += column.width + columnSpacing
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Иконка-индикатор

    private func showIcon(severity: Severity, symbolOverride: String? = nil) {
        guard let button = statusItem.button else { return }
        let symbol = symbolOverride ?? severity.thermometerSymbol
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Температура") {
            image.isTemplate = true
            button.image = image
            button.contentTintColor = severity.iconTint
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.image = nil
            button.title = "🌡"
        }
    }

    // MARK: - Уведомления о перегреве (разово, с гистерезисом)

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkOverheat(_ temps: [Metric: Double]) {
        for (metric, value) in temps {
            if value >= critThreshold {
                if !activeAlerts.contains(metric) {
                    activeAlerts.insert(metric)
                    sendOverheatNotification(metric: metric, value: value)
                }
            } else if value < rearmThreshold {
                // Остыло ниже порога перевзвода — снова разрешаем уведомление.
                activeAlerts.remove(metric)
            }
        }
    }

    private func sendOverheatNotification(metric: Metric, value: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Перегрев: \(metric.menuTitle)"
        content.body = "Температура \(format(value))"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "overheat.\(metric.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Меню (лениво при открытии)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if sensors.isAvailable {
            let header = NSMenuItem(title: "Показывать в статусбаре:", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for metric in Metric.allCases {
                menu.addItem(makeMetricItem(metric))
            }

            menu.addItem(.separator())
            let historyToggle = NSMenuItem(
                title: "Отображать историю замеров",
                action: #selector(toggleHistory),
                keyEquivalent: ""
            )
            historyToggle.target = self
            historyToggle.state = showHistory ? .on : .off
            menu.addItem(historyToggle)

            if showHistory {
                menu.addItem(makeGraphItem())
            }
        } else {
            let item = NSMenuItem(title: "SMC недоступен", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(makeIntervalSubmenu())
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // Пункт-переключатель: текущее значение + галочка.
    private func makeMetricItem(_ metric: Metric) -> NSMenuItem {
        let value = sensors.temperature(for: metric)
        let item = NSMenuItem(
            title: "\(metric.menuTitle):  \(format(value))",
            action: #selector(toggleMetric(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = metric.rawValue
        item.state = selectedMetrics.contains(metric) ? .on : .off
        return item
    }

    // Пункт меню с нарисованным графиком истории.
    private func makeGraphItem() -> NSMenuItem {
        // Показываем выбранные метрики; если ничего не выбрано — все.
        let metrics = selectedMetrics.isEmpty
            ? Metric.allCases
            : Metric.allCases.filter { selectedMetrics.contains($0) }

        let series = metrics.compactMap { metric -> GraphView.Series? in
            let points = sensors.history(for: metric)
            guard points.count >= 2 else { return nil }
            return GraphView.Series(label: metric.shortLabel, color: metric.graphColor, points: points)
        }

        let item = NSMenuItem()
        item.view = GraphView(series: series, size: NSSize(width: 260, height: 110))
        return item
    }

    @objc private func toggleHistory() {
        showHistory.toggle()
        UserDefaults.standard.set(showHistory, forKey: historyKey)
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let metric = Metric(rawValue: raw)
        else { return }

        if selectedMetrics.contains(metric) {
            selectedMetrics.remove(metric)
        } else {
            selectedMetrics.insert(metric)
        }
        saveSelection()
        tick()
    }

    private func makeIntervalSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Интервал обновления", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for seconds in [1.0, 2.0, 5.0, 10.0] {
            let item = NSMenuItem(
                title: "\(Int(seconds)) сек",
                action: #selector(setInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = seconds
            item.state = (seconds == refreshInterval) ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        refreshInterval = seconds
        startTimer()
        tick()
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))°"
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
