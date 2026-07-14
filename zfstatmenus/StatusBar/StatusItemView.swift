import AppKit

struct History {
    private let maxCount: Int
    private var values: [Double]

    init(maxCount: Int = 60) {
        self.maxCount = maxCount
        self.values = []
    }

    mutating func push(_ value: Double) {
        values.append(value)
        if values.count > maxCount {
            values.removeFirst()
        }
    }

    var all: [Double] { values }
    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }
    var last: Double? { values.last }

    mutating func clear() {
        values.removeAll()
    }
}

// MARK: - StatusItemView

final class StatusItemView: NSView {

    let type: StatusItemType

    var onWidthChange: ((CGFloat) -> Void)?

    // CPU
    private var perCoreUsage: [Double] = []
    private var cpuPercent: Int = 0

    // Memory
    private var memRatio: Double = 0
    private var memText: String = ""

    // Network
    private var downText: String = "0 KB/s"
    private var upText: String = "0 KB/s"

    // Token
    private var tokenText: String = "0"

    private var lastReportedWidth: CGFloat = 0

    init(type: StatusItemType) {
        self.type = type
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func updateCPU(perCore: [Double], overall: Double) {
        perCoreUsage = perCore
        cpuPercent = Int(overall * 100)
        needsDisplay = true
    }

    func updateMemory(ratio: Double, text: String) {
        memRatio = ratio
        memText = text
        needsDisplay = true
    }

    func updateNetwork(down: String, up: String) {
        downText = down
        upText = up

        // 网络项为两行布局，宽度只由较长的一行决定。
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let arrowWidth = ("↗" as NSString).size(withAttributes: attrs).width
        let valueWidth = max(
            (downText as NSString).size(withAttributes: attrs).width,
            (upText as NSString).size(withAttributes: attrs).width
        )
        let needed: CGFloat = 8 + arrowWidth + 4 + valueWidth + 8
        reportWidthIfNeeded(needed)

        needsDisplay = true
    }

    func updateToken(today: Int64) {
        tokenText = formatTokenCount(today)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let valueWidth = (tokenText as NSString).size(withAttributes: [.font: font]).width
        reportWidthIfNeeded(6 + 16 + 4 + valueWidth + 6)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawBackground(in: bounds)

        let contentRect = bounds.insetBy(dx: 3, dy: 0)

        switch type {
        case .cpu:
            drawCPU(in: contentRect)
        case .memory:
            drawMemory(in: contentRect)
        case .network:
            drawNetwork(in: contentRect)
        case .token:
            drawToken(in: contentRect)
        }
    }

    // MARK: Background

    private func drawBackground(in rect: NSRect) {
        let background = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.black.setFill()
        background.fill()
    }

    // MARK: Helpers

    private var accentColor: NSColor {
        .systemBlue
    }

    @discardableResult
    private func drawSymbol(_ name: String, fallback: String, in rect: NSRect, centered: Bool = false) -> CGFloat {
        let symbolSize: CGFloat = 16
        let symbolRect = NSRect(
            x: centered ? rect.midX - symbolSize / 2 : rect.minX,
            y: rect.midY - symbolSize / 2,
            width: symbolSize,
            height: symbolSize
        )
        let pointConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        let colorConfiguration = NSImage.SymbolConfiguration(hierarchicalColor: .white)
        let configuration = pointConfiguration.applying(colorConfiguration)

        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            image.draw(in: symbolRect)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let string = fallback as NSString
            let size = string.size(withAttributes: attributes)
            string.draw(
                at: NSPoint(x: symbolRect.midX - size.width / 2, y: symbolRect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
        return symbolSize
    }

    @discardableResult
    private func drawTemplateAsset(_ name: NSImage.Name, fallback: String, in rect: NSRect) -> CGFloat {
        let reservedWidth: CGFloat = 16
        let imageRect = NSRect(
            x: rect.minX,
            y: rect.midY - 8,
            width: 16,
            height: 16
        )

        if let sourceImage = NSImage(named: name),
           let image = sourceImage.copy() as? NSImage {
            image.size = imageRect.size
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
            image.unlockFocus()
            image.draw(in: imageRect)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let string = fallback as NSString
            let size = string.size(withAttributes: attributes)
            string.draw(
                at: NSPoint(x: imageRect.midX - size.width / 2, y: imageRect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
        return reservedWidth
    }

    private func drawRightText(_ text: String, in rect: NSRect, color: NSColor = .white) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color,
        ]
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        let textRect = NSRect(
            x: rect.maxX - size.width,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        str.draw(in: textRect, withAttributes: attrs)
    }

    // MARK: CPU

    private func drawCPU(in rect: NSRect) {
        let iconWidth = drawSymbol("cpu", fallback: "C", in: rect)

        let rightText = "\(cpuPercent)%"
        drawRightText(rightText, in: rect)

        let rightWidth = (rightText as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        ]).width

        let gap: CGFloat = 5
        let barArea = NSRect(
            x: rect.minX + iconWidth + gap,
            y: rect.minY + 1,
            width: rect.width - iconWidth - gap - rightWidth - gap,
            height: rect.height - 2
        )

        guard !perCoreUsage.isEmpty, barArea.width > 4 else { return }

        let barCount = perCoreUsage.count
        let barGap: CGFloat = 1
        let barWidth = max(1.5, (barArea.width - CGFloat(barCount - 1) * barGap) / CGFloat(barCount))

        for (i, usage) in perCoreUsage.enumerated() {
            let h = barArea.height * CGFloat(max(usage, 0.03))
            let barRect = NSRect(
                x: barArea.minX + CGFloat(i) * (barWidth + barGap),
                y: barArea.minY,
                width: barWidth,
                height: max(1, h)
            )
            let path = NSBezierPath(roundedRect: barRect, xRadius: 0.5, yRadius: 0.5)
            // Brighter color for higher usage, dimmer for lower — but all fully opaque
            let brightness = 0.35 + 0.65 * CGFloat(usage)
            path.fill(withColor: accentColor, brightness: brightness)
        }
    }

    // MARK: Memory

    private func drawMemory(in rect: NSRect) {
        let iconWidth = drawSymbol("memorychip", fallback: "M", in: rect)

        drawRightText(memText, in: rect)

        let rightWidth = (memText as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        ]).width

        let gap: CGFloat = 5
        let barArea = NSRect(
            x: rect.minX + iconWidth + gap,
            y: rect.minY,
            width: rect.width - iconWidth - gap - rightWidth - gap,
            height: rect.height
        )

        guard barArea.width > 4 else { return }

        let trackHeight: CGFloat = min(barArea.height, 8)
        let trackRect = NSRect(
            x: barArea.minX,
            y: barArea.midY - trackHeight / 2,
            width: barArea.width,
            height: trackHeight
        )

        // 暗色轨道与黑色背景保持层次，占用部分使用蓝色柱形。
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
        NSColor.white.withAlphaComponent(0.18).setFill()
        trackPath.fill()

        // Fill — fully opaque accent color
        let fillWidth = trackRect.width * CGFloat(min(max(memRatio, 0), 1))
        if fillWidth > 1 {
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
            accentColor.setFill()
            fillPath.fill()
        }
    }

    // MARK: Network

    private func drawNetwork(in rect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]

        // 与参考图一致：上传在上，下载在下，数值右对齐。
        drawNetworkLine(arrow: "↗", value: upText, in: upperHalf(of: rect), attributes: attrs)
        drawNetworkLine(arrow: "↙", value: downText, in: lowerHalf(of: rect), attributes: attrs)
    }

    private func upperHalf(of rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    }

    private func lowerHalf(of rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
    }

    private func drawNetworkLine(
        arrow: String,
        value: String,
        in rect: NSRect,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let arrowString = arrow as NSString
        let valueString = value as NSString
        let arrowSize = arrowString.size(withAttributes: attributes)
        let valueSize = valueString.size(withAttributes: attributes)

        arrowString.draw(
            at: NSPoint(x: rect.minX, y: rect.midY - arrowSize.height / 2),
            withAttributes: attributes
        )
        valueString.draw(
            at: NSPoint(x: rect.maxX - valueSize.width, y: rect.midY - valueSize.height / 2),
            withAttributes: attributes
        )
    }

    // MARK: Token

    private func drawToken(in rect: NSRect) {
        let iconWidth = drawTemplateAsset("TokenGlyph", fallback: "T", in: rect)
        let textRect = NSRect(
            x: rect.minX + iconWidth + 4,
            y: rect.minY,
            width: rect.width - iconWidth - 4,
            height: rect.height
        )
        drawRightText(tokenText, in: textRect)
    }

    private func reportWidthIfNeeded(_ width: CGFloat) {
        let rounded = (width * 2).rounded() / 2
        if abs(rounded - lastReportedWidth) > 0.5 {
            lastReportedWidth = rounded
            onWidthChange?(rounded)
        }
    }
}

// MARK: - NSBezierPath color helper

private extension NSBezierPath {
    func fill(withColor color: NSColor, brightness: CGFloat) {
        let hsb = color.usingColorSpace(.sRGB) ?? color
        if let adjusted = NSColor(
            hue: hsb.hueComponent,
            saturation: hsb.saturationComponent,
            brightness: min(1, hsb.brightnessComponent * (0.5 + 0.5 * brightness)),
            alpha: 1
        ).usingColorSpace(.sRGB) {
            adjusted.setFill()
        } else {
            color.setFill()
        }
        self.fill()
    }
}
