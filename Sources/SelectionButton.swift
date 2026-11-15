import AppKit

// The small button shown next to a fresh selection (like Youdao or Easydict): nothing is sent until the user
// rests the pointer on it (hover mode) or clicks it (click mode). It never takes focus, so the selection stays.

enum SelectionButtonPolicy {
    static let size = NSSize(width: 30, height: 30)
    static let hoverDwell: TimeInterval = 0.12      // ignore a pointer that only sweeps across the button
    static let idleTimeout: TimeInterval = 4        // unused buttons disappear
    static let dismissDistance: CGFloat = 140       // moving this far from the button means "not interested"

    /// Below and to the right of where the mouse was released, so it never covers the end of the selection;
    /// above the point when there is no room below. Kept fully on screen.
    static func origin(near point: NSPoint, in area: NSRect) -> NSPoint {
        var x = point.x + 10
        var y = point.y - size.height - 12
        if y < area.minY + 4 { y = point.y + 14 }
        x = min(max(x, area.minX + 4), area.maxX - size.width - 4)
        y = min(max(y, area.minY + 4), area.maxY - size.height - 4)
        return NSPoint(x: x, y: y)
    }

    static func tooFar(_ point: NSPoint, from frame: NSRect) -> Bool {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return hypot(dx, dy) > dismissDistance
    }

    /// Holding Command while selecting suppresses the button (PopClip convention).
    static func suppressed(_ flags: NSEvent.ModifierFlags) -> Bool { flags.contains(.command) }
}

private final class ButtonPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ButtonView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityRole(.button)
        setAccessibilityLabel("Translate selection")
    }
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true; onEnter?() }
    override func mouseExited(with event: NSEvent) { hovered = false; onExit?() }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        (hovered ? NSColor.controlAccentColor : NSColor.windowBackgroundColor).setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "character.book.closed.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let tint: NSColor = hovered ? .white : .controlAccentColor
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.draw(in: NSRect(x: (bounds.width - symbol.size.width) / 2, y: (bounds.height - symbol.size.height) / 2,
                              width: symbol.size.width, height: symbol.size.height))
    }
}

@MainActor final class SelectionButton {
    private let panel: ButtonPanel
    private let button: ButtonView
    private var monitors: [Any] = []
    private var dwellTimer: Timer?
    private var idleTimer: Timer?
    private var action: (@MainActor () -> Void)?
    private var hoverTriggers = true
    var visible: Bool { panel.isVisible }
    var onDismiss: ((String) -> Void)?

    init() {
        panel = ButtonPanel(contentRect: NSRect(origin: .zero, size: SelectionButtonPolicy.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        button = ButtonView(frame: NSRect(origin: .zero, size: SelectionButtonPolicy.size))
        panel.contentView = button
        button.onEnter = { [weak self] in self?.entered() }
        button.onExit = { [weak self] in self?.exited() }
        button.onClick = { [weak self] in self?.fire("click") }
    }

    /// Shows the button near `point`; `action` runs once, on hover (after a short rest) or click.
    func show(near point: NSPoint, hover: Bool, action: @escaping @MainActor () -> Void) {
        hide(reason: nil)
        guard let area = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame else { return }
        self.action = action
        hoverTriggers = hover
        panel.setFrameOrigin(SelectionButtonPolicy.origin(near: point, in: area))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let panel = self.panel
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.08; panel.animator().alphaValue = 1 }
        restartIdleTimer()
        // While visible: moving away, typing, scrolling or clicking elsewhere dismisses it.
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.visible else { return }
                if SelectionButtonPolicy.tooFar(NSEvent.mouseLocation, from: self.panel.frame) { self.hide(reason: "moved_away") }
            }
        }) { monitors.append(moved) }
        if let other = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(reason: "other_input") }
        }) { monitors.append(other) }
    }

    func hide(reason: String?) {
        dwellTimer?.invalidate(); dwellTimer = nil
        idleTimer?.invalidate(); idleTimer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        let wasVisible = panel.isVisible
        action = nil
        panel.orderOut(nil)
        if wasVisible, let reason { onDismiss?(reason) }
    }

    private func entered() {
        idleTimer?.invalidate(); idleTimer = nil
        guard hoverTriggers else { return }
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: SelectionButtonPolicy.hoverDwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire("hover") }
        }
    }

    private func exited() {
        dwellTimer?.invalidate(); dwellTimer = nil
        if visible { restartIdleTimer() }
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: SelectionButtonPolicy.idleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(reason: "timeout") }
        }
    }

    private func fire(_ how: String) {
        guard let action else { return }
        if StageProfiler.enabled { print("TranslateGPT phase=button_triggered by=\(how)"); fflush(stdout) }
        hide(reason: nil)
        action()
    }
}
