import Cocoa

// Лёгкий линейный график истории температур для пункта меню.
final class GraphView: NSView {
    struct Series {
        let label: String
        let color: NSColor
        let points: [Double]
    }

    private let series: [Series]

    private let leftInset: CGFloat = 30
    private let topInset: CGFloat = 18   // место под легенду
    private let rightInset: CGFloat = 8
    private let bottomInset: CGFloat = 8

    init(series: [Series], size: NSSize) {
        self.series = series
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(
            x: leftInset,
            y: bottomInset,
            width: bounds.width - leftInset - rightInset,
            height: bounds.height - topInset - bottomInset
        )

        guard !series.isEmpty else {
            drawCenteredText("нет данных", in: bounds)
            return
        }

        let allValues = series.flatMap(\.points)
        guard let rawMin = allValues.min(), let rawMax = allValues.max() else { return }

        // Небольшой отступ по краям шкалы, минимальный диапазон чтобы линия не была плоской.
        var yMin = floor(rawMin - 2)
        var yMax = ceil(rawMax + 2)
        if yMax - yMin < 6 { yMax = yMin + 6 }
        let yRange = yMax - yMin

        drawAxisLabels(yMin: yMin, yMax: yMax, plot: plot)
        drawLegend()

        for s in series where s.points.count >= 2 {
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineJoinStyle = .round

            let n = s.points.count
            for (i, value) in s.points.enumerated() {
                let x = plot.minX + CGFloat(i) / CGFloat(n - 1) * plot.width
                let y = plot.minY + CGFloat((value - yMin) / yRange) * plot.height
                let point = NSPoint(x: x, y: y)
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            s.color.setStroke()
            path.stroke()
        }
    }

    private func drawAxisLabels(yMin: Double, yMax: Double, plot: NSRect) {
        // Тонкая рамка области графика.
        NSColor.separatorColor.setStroke()
        let frame = NSBezierPath(rect: plot)
        frame.lineWidth = 0.5
        frame.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let top = "\(Int(yMax))°" as NSString
        let bottom = "\(Int(yMin))°" as NSString
        top.draw(at: NSPoint(x: 4, y: plot.maxY - 7), withAttributes: attrs)
        bottom.draw(at: NSPoint(x: 4, y: plot.minY - 2), withAttributes: attrs)
    }

    private func drawLegend() {
        var x: CGFloat = leftInset
        let y = bounds.height - topInset + 3
        for s in series {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: s.color
            ]
            let text = s.label as NSString
            text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            x += text.size(withAttributes: attrs).width + 10
        }
    }

    private func drawCenteredText(_ text: String, in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attrs)
        let point = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        string.draw(at: point, withAttributes: attrs)
    }
}
