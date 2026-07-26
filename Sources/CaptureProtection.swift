import UIKit

// MARK: - Palette

extension UIColor {
    /// VOLTAGE volt-yellow #FFD400 — the team accent.
    static let voltageYellow = UIColor(red: 1.0, green: 212.0 / 255.0, blue: 0.0, alpha: 1.0)
}

// MARK: - Diagnostics

/// Always-on record of what the capture protection actually did, so a
/// **real-device screenshot test** can tell the difference between "the web
/// view really is inside the secure canvas" and "the web view is hosted
/// normally and everything lands in the screenshot".
///
/// Two ways to read it on device:
///  - every line is logged with the `[3134S capture]` prefix (Xcode console,
///    or Console.app with the phone attached),
///  - `CaptureProtectionDiagnostics.isSecureCanvasActive` is a plain static
///    boolean — break on it in lldb, or `po` it.
///
/// The boolean says the *hosting* is in place. It cannot say the capture
/// exclusion propagates into WKWebView's out-of-process layer — only a
/// screenshot on a real device can (see `hostedContentUsesRemoteLayer`).
enum CaptureProtectionDiagnostics {

    /// True only while protected content is parented inside a positively
    /// identified secure canvas. False means captures show everything.
    private(set) static var isSecureCanvasActive = false

    /// Runtime class name of the view accepted as the secure canvas.
    private(set) static var secureCanvasClassName: String?

    /// Why the secure canvas was rejected or given up, when it was.
    private(set) static var lastFailureReason: String?

    /// True when the hosted content draws through an out-of-process layer host
    /// — WKWebView does. Whether such a layer inherits the secure canvas's
    /// capture exclusion is exactly the thing a device screenshot must settle;
    /// the simulator's screenshot path does not model it.
    private(set) static var hostedContentUsesRemoteLayer = false

    private static var lastLoggedSummary: String?

    static func log(_ message: String) {
        NSLog("[3134S capture] %@", message)
    }

    static func recordCanvasAccepted(_ canvas: UIView) {
        secureCanvasClassName = String(describing: type(of: canvas))
        lastFailureReason = nil
        log("secure canvas accepted: \(secureCanvasClassName ?? "?") bounds=\(canvas.bounds.size)")
    }

    static func recordFailure(_ reason: String) {
        isSecureCanvasActive = false
        lastFailureReason = reason
        log("capture protection OFF — \(reason)")
    }

    /// Records where the content actually ended up. Logs only when the picture
    /// changes, so this is safe to call from layout/navigation callbacks.
    static func recordHosting(active: Bool, content: UIView) {
        isSecureCanvasActive = active
        hostedContentUsesRemoteLayer = usesRemoteLayerHost(content)
        if summary != lastLoggedSummary {
            lastLoggedSummary = summary
            log(summary)
        }
    }

    static var summary: String {
        if isSecureCanvasActive {
            let canvasName = secureCanvasClassName ?? "the secure canvas"
            let remote = hostedContentUsesRemoteLayer ? "YES" : "no"
            return "PROTECTED(hosting): content is inside \(canvasName); out-of-process layer host: "
                + "\(remote). DEVICE TEST REQUIRED: take a screenshot on a real iPhone and confirm "
                + "the dashboard comes out black — a hosted WKWebView layer is not guaranteed to "
                + "inherit the canvas capture exclusion, and the simulator cannot answer this."
        }
        let reason = lastFailureReason ?? "secure canvas unavailable"
        return "UNPROTECTED: content is hosted normally and WILL appear in screenshots, screen "
            + "recordings and mirroring. Reason: \(reason)"
    }

    /// Heuristic: does this view tree draw through a remote/hosted layer?
    private static func usesRemoteLayerHost(_ view: UIView) -> Bool {
        var stack: [(layer: CALayer, depth: Int)] = [(layer: view.layer, depth: 0)]
        while let entry = stack.popLast() {
            let name = String(describing: type(of: entry.layer))
            if name.contains("LayerHost") || name.contains("Remote") { return true }
            guard entry.depth < 6 else { continue }
            for sublayer in entry.layer.sublayers ?? [] {
                stack.append((layer: sublayer, depth: entry.depth + 1))
            }
        }
        return false
    }
}

// MARK: - Secure canvas host

/// Hosts content inside the private "secure canvas" UIKit renders password
/// fields into. That canvas is flagged as capture-excluded by the window
/// server, so anything parented into it stays fully visible on device but
/// comes out solid black in screenshots, screen recordings and mirroring.
///
/// The canvas lives in a private view hierarchy, so every step here is
/// validated — twice, and positively:
///
///  1. **Identity.** A candidate is used only when it is the field's own
///     designated secure content view or its class is the private secure
///     canvas type. Grabbing `subviews.first` is not good enough: on a
///     reshaped hierarchy that parks the content in an ordinary, fully
///     capturable view while the app still believes it is protected.
///  2. **Usability.** The canvas must actually resize with its host. UIKit
///     sizes it to a single text line by default, and a "height > 1" check
///     happily accepts that — the dashboard then gets squeezed into a ~20pt
///     sliver. It is probed at two known, non-trivial sizes before anything
///     reaches the screen, and re-checked whenever the caller asks.
///
/// If either check fails, `install(in:topAnchor:)` returns `nil` and the caller
/// must host its content normally *and stop claiming protection*: a
/// screenshottable app is a far better failure mode than a blank or lying one.
final class SecureContentHost {

    /// Sizes the canvas is probed at. Two different ones, because a canvas that
    /// merely happens to match a size is not the same as one that resizes with
    /// its host.
    private static let probeSizes = [
        CGSize(width: 320, height: 480),
        CGSize(width: 390, height: 760),
    ]

    /// The canvas must cover at least this fraction of its host in both axes.
    /// A text-line rect misses it by a mile, which is the point.
    private static let minimumHostCoverage: CGFloat = 0.9

    /// Below this the host is too small to judge a canvas by.
    private static let minimumUsableSide: CGFloat = 44

    /// Class-name fragments UIKit has used for the capture-excluded canvas.
    private static let secureCanvasNameFragments = [
        "CanvasView",       // _UITextLayoutCanvasView
        "SecureCanvas",
        "TextLayoutCanvas",
    ]

    /// Private accessors that vend the field's designated secure content view.
    /// Each is probed with `responds(to:)` first, so a missing one is a no-op.
    private static let secureContentViewSelectorNames = [
        "_secureCanvasView",
        "secureCanvasView",
        "_textLayoutCanvasView",
        "textLayoutCanvasView",
    ]

    /// How the canvas is made to follow its host. UIKit lays a text field's own
    /// subviews out by hand, so neither approach is guaranteed to win — each is
    /// tried and then *proved* before the content goes anywhere near it.
    private enum SizingStrategy: Equatable {
        case constraints
        case autoresizing
    }

    /// The field exists only to vend its secure canvas — it must never edit
    /// text, show a caret, or swallow a touch meant for the hosted content.
    private final class HostTextField: UITextField {
        override var canBecomeFirstResponder: Bool { false }
        override func becomeFirstResponder() -> Bool { false }
        override func caretRect(for position: UITextPosition) -> CGRect { .zero }
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

        /// Hits land on the hosted content or fall through to whatever is
        /// behind the field; the field itself is never the target.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }

    private let field = HostTextField()

    /// The capture-excluded view hosting the content, once installed.
    private(set) var canvas: UIView?

    /// Constraints pinning the field to its container, kept so the resize probe
    /// can step out of them and put it back.
    private var hostConstraints: [NSLayoutConstraint] = []

    /// Constraints pinning the canvas full-bleed to the field, when the
    /// constraint strategy is the one that held.
    private var canvasConstraints: [NSLayoutConstraint] = []

    private var sizingStrategy: SizingStrategy = .constraints

    /// `nil` while the secure canvas still looks like a live, visible,
    /// correctly sized host; otherwise a short reason it no longer does.
    var unhealthyReason: String? {
        guard let canvas = canvas else { return "no secure canvas installed" }
        if !field.isSecureTextEntry { return "host field is no longer secure" }
        if field.window == nil { return "host field left the window" }
        if canvas.superview !== field { return "canvas was reparented away from the host field" }
        if canvas.isHidden { return "canvas is hidden" }
        if canvas.alpha <= 0.01 { return "canvas is transparent" }
        if !Self.isUsableCanvas(canvas, hostedIn: field) {
            return "canvas \(canvas.bounds.size) does not fill host \(field.bounds.size)"
        }
        return nil
    }

    /// True while the secure canvas still looks like a live, visible host that
    /// is genuinely big enough to hold the content.
    var isHealthy: Bool { unhealthyReason == nil }

    /// Installs the secure host as a subview of `container`, pinned full-bleed
    /// on the sides and bottom and to `topAnchor` up top (so callers keep their
    /// safe-area pinning).
    ///
    /// - Returns: the capture-excluded view to add content to, or `nil` when
    ///   the private hierarchy did not look the way we expect, or the canvas
    ///   would not resize with its host. `nil` means: host normally, and do not
    ///   tell the user anything is protected.
    @discardableResult
    func install(in container: UIView, topAnchor: NSLayoutYAxisAnchor? = nil) -> UIView? {
        configureField()

        container.addSubview(field)
        hostConstraints = [
            field.topAnchor.constraint(equalTo: topAnchor ?? container.topAnchor),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        NSLayoutConstraint.activate(hostConstraints)

        // UIKit builds the canvas lazily — force a layout pass before looking.
        container.layoutIfNeeded()

        guard let canvas = Self.locateSecureCanvas(in: field) else {
            tearDown()
            CaptureProtectionDiagnostics.recordFailure(
                "no subview of the host field could be positively identified as the secure canvas"
            )
            return nil
        }

        // The canvas UIKit hands back is sized to one line of text. Prove it
        // follows the host at real sizes before trusting it with the dashboard
        // — otherwise the user gets a ~20pt sliver instead of a screen.
        var failures: [String] = []
        for strategy in [SizingStrategy.constraints, .autoresizing] {
            adopt(canvas, using: strategy)
            container.layoutIfNeeded()

            guard let failure = resizeProbeFailure(canvas, using: strategy) else {
                self.canvas = canvas
                CaptureProtectionDiagnostics.recordCanvasAccepted(canvas)
                return canvas
            }
            failures.append(failure)
            release(canvas)
        }

        tearDown()
        CaptureProtectionDiagnostics.recordFailure(failures.joined(separator: "; "))
        return nil
    }

    /// Re-asserts the canvas geometry/visibility UIKit may reset behind our
    /// back (e.g. after a layout pass or a trip through the background).
    func enforceVisibility() {
        guard let canvas = canvas, canvas.superview === field else { return }
        if canvas.isHidden { canvas.isHidden = false }
        if canvas.alpha < 0.99 { canvas.alpha = 1 }
        if !field.isSecureTextEntry { field.isSecureTextEntry = true }

        // The field lays its own subviews out; when we are sizing the canvas by
        // hand, put it back full-bleed if UIKit shrank it to a text line.
        if sizingStrategy == .autoresizing,
           field.bounds.width > 1,
           field.bounds.height > 1,
           !Self.isUsableCanvas(canvas, hostedIn: field) {
            canvas.frame = field.bounds
        }
    }

    /// Tears the host back out, handing `content` back to the caller unparented.
    func uninstall(releasing content: UIView?) {
        content?.removeFromSuperview()
        if let canvas = canvas { release(canvas) }
        canvas = nil
        tearDown()
    }

    // MARK: - Setup

    private func configureField() {
        field.isSecureTextEntry = true
        field.text = ""
        field.backgroundColor = .clear
        field.textColor = .clear
        field.tintColor = .clear
        field.borderStyle = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.clearButtonMode = .never
        field.isAccessibilityElement = false
        field.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Takes ownership of the canvas: strips UIKit's text-rendering subviews
    /// and makes it full-bleed inside the field by `strategy`.
    private func adopt(_ canvas: UIView, using strategy: SizingStrategy) {
        canvas.subviews.forEach { $0.removeFromSuperview() }
        canvas.isUserInteractionEnabled = true
        canvas.backgroundColor = .clear
        canvas.isHidden = false
        canvas.alpha = 1

        switch strategy {
        case .constraints:
            canvas.translatesAutoresizingMaskIntoConstraints = false
            canvasConstraints = [
                canvas.topAnchor.constraint(equalTo: field.topAnchor),
                canvas.leadingAnchor.constraint(equalTo: field.leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: field.trailingAnchor),
                canvas.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            ]
            NSLayoutConstraint.activate(canvasConstraints)
        case .autoresizing:
            canvas.translatesAutoresizingMaskIntoConstraints = true
            canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            canvas.frame = field.bounds
        }

        sizingStrategy = strategy
    }

    /// Hands the canvas back to UIKit's own layout.
    private func release(_ canvas: UIView) {
        NSLayoutConstraint.deactivate(canvasConstraints)
        canvasConstraints = []
        canvas.translatesAutoresizingMaskIntoConstraints = true
        canvas.autoresizingMask = []
    }

    private func tearDown() {
        NSLayoutConstraint.deactivate(hostConstraints)
        hostConstraints = []
        field.removeFromSuperview()
    }

    // MARK: - Validation

    /// Forces the host field to two known, non-trivial sizes and requires the
    /// canvas to follow it both times, laying the field out in between so
    /// UIKit's own subview positioning gets its chance to stomp us.
    ///
    /// A canvas left at a text-line rect fails here — which is the whole point:
    /// it sails through any "bounds are bigger than a pixel" test while being
    /// completely useless as a host for a full-screen dashboard.
    ///
    /// - Returns: `nil` when the canvas tracked its host, else why it did not.
    private func resizeProbeFailure(_ canvas: UIView, using strategy: SizingStrategy) -> String? {
        let savedFrame = field.frame
        NSLayoutConstraint.deactivate(hostConstraints)
        field.translatesAutoresizingMaskIntoConstraints = true

        defer {
            field.frame = savedFrame
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate(hostConstraints)
            field.superview?.setNeedsLayout()
            field.superview?.layoutIfNeeded()
            if strategy == .autoresizing, field.bounds.width > 1, field.bounds.height > 1 {
                canvas.frame = field.bounds
            }
        }

        for size in Self.probeSizes {
            field.frame = CGRect(origin: .zero, size: size)
            if strategy == .autoresizing {
                canvas.frame = field.bounds
            }
            field.setNeedsLayout()
            field.layoutIfNeeded()

            guard Self.isUsableCanvas(canvas, hostedIn: field) else {
                let percent = Int(Self.minimumHostCoverage * 100)
                return "\(strategy): canvas stayed \(canvas.bounds.size) inside a \(size) host "
                    + "(needs \(percent)% of both axes) — UIKit is holding it at a text-line rect"
            }
        }
        return nil
    }

    /// True when `canvas` genuinely covers `host` in both axes. UIKit's
    /// untouched canvas is one text line tall, which is not a usable host for a
    /// full-screen dashboard however non-zero its bounds are.
    private static func isUsableCanvas(_ canvas: UIView, hostedIn host: UIView) -> Bool {
        let hostSize = host.bounds.size
        guard hostSize.width >= minimumUsableSide, hostSize.height >= minimumUsableSide else {
            return false
        }
        let size = canvas.bounds.size
        return size.width >= hostSize.width * minimumHostCoverage
            && size.height >= hostSize.height * minimumHostCoverage
    }

    /// Positively identifies the capture-excluded canvas. Returns `nil` rather
    /// than guessing: an unidentified view may well be an ordinary, fully
    /// capturable one, and hosting content there while reporting "protected" is
    /// worse than having no protection at all.
    private static func locateSecureCanvas(in field: UITextField) -> UIView? {
        // 1. The field's own designated secure content view, if it vends one.
        if let designated = designatedSecureContentView(of: field),
           designated !== field,
           designated.superview === field {
            return designated
        }

        // 2. A child whose runtime class is the private secure canvas type.
        var candidates: [UIView] = field.subviews
        if let layerDelegate = field.layer.sublayers?.first?.delegate as? UIView {
            candidates.append(layerDelegate)
        }
        for candidate in candidates
        where candidate !== field && candidate.superview === field && isSecureCanvasClass(candidate) {
            return candidate
        }

        let seen = candidates.map { String(describing: type(of: $0)) }
        CaptureProtectionDiagnostics.log(
            "no secure canvas identified in \(type(of: field)); rejected candidates: \(seen)"
        )
        return nil
    }

    private static func isSecureCanvasClass(_ view: UIView) -> Bool {
        let name = String(describing: type(of: view))
        return secureCanvasNameFragments.contains { name.contains($0) }
    }

    private static func designatedSecureContentView(of field: UITextField) -> UIView? {
        for name in secureContentViewSelectorNames {
            let selector = NSSelectorFromString(name)
            guard field.responds(to: selector),
                  let value = field.perform(selector)?.takeUnretainedValue() as? UIView
            else { continue }
            CaptureProtectionDiagnostics.log(
                "host field designated its secure content view via -\(name): \(type(of: value))"
            )
            return value
        }
        return nil
    }
}

// MARK: - Capture notice overlay

/// Full-bleed charcoal curtain shown when the screen is being recorded or a
/// screenshot was just taken.
final class CaptureNoticeView: UIView {

    /// Whether the curtain is reporting protection or the absence of it. The
    /// app must never show the reassuring version when the secure canvas is not
    /// actually hosting the content.
    enum Tone {
        case protected
        case exposed

        var symbolName: String {
            switch self {
            case .protected: return "lock.fill"
            case .exposed: return "exclamationmark.triangle.fill"
            }
        }

        var fallbackGlyph: String {
            switch self {
            case .protected: return "\u{1F512}"
            case .exposed: return "\u{26A0}\u{FE0F}"
            }
        }

        var accent: UIColor {
            switch self {
            case .protected: return .voltageYellow
            case .exposed: return UIColor(red: 1.0, green: 0.42, blue: 0.35, alpha: 1.0)
            }
        }
    }

    private let glyphContainer = UIView()
    private let glyphImage = UIImageView()
    private let glyphFallback = UILabel()
    private let messageLabel = UILabel()

    /// What the curtain is currently claiming. Readable so callers can assert
    /// the app is not showing the reassuring version unprotected.
    private(set) var tone: Tone = .protected

    init(message: String, tone: Tone) {
        super.init(frame: .zero)
        backgroundColor = .voltageCharcoal
        isAccessibilityElement = true
        accessibilityViewIsModal = true
        translatesAutoresizingMaskIntoConstraints = false

        glyphContainer.translatesAutoresizingMaskIntoConstraints = false
        glyphContainer.layer.cornerRadius = 44
        glyphContainer.layer.borderWidth = 1

        glyphImage.translatesAutoresizingMaskIntoConstraints = false
        glyphImage.contentMode = .scaleAspectFit

        // If the symbol is ever unavailable, a plain glyph still reads.
        glyphFallback.translatesAutoresizingMaskIntoConstraints = false
        glyphFallback.font = .systemFont(ofSize: 38)
        glyphFallback.textAlignment = .center

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.textColor = UIColor(white: 0.96, alpha: 1)
        messageLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        glyphContainer.addSubview(glyphImage)
        glyphContainer.addSubview(glyphFallback)
        addSubview(glyphContainer)
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            glyphContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphContainer.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -36),
            glyphContainer.widthAnchor.constraint(equalToConstant: 88),
            glyphContainer.heightAnchor.constraint(equalToConstant: 88),

            glyphImage.centerXAnchor.constraint(equalTo: glyphContainer.centerXAnchor),
            glyphImage.centerYAnchor.constraint(equalTo: glyphContainer.centerYAnchor),
            glyphFallback.centerXAnchor.constraint(equalTo: glyphContainer.centerXAnchor),
            glyphFallback.centerYAnchor.constraint(equalTo: glyphContainer.centerYAnchor),

            messageLabel.topAnchor.constraint(equalTo: glyphContainer.bottomAnchor, constant: 22),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])

        apply(message: message, tone: tone)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(message: String, tone: Tone) {
        self.tone = tone

        glyphContainer.backgroundColor = tone.accent.withAlphaComponent(0.12)
        glyphContainer.layer.borderColor = tone.accent.withAlphaComponent(0.45).cgColor

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 38, weight: .semibold)
        glyphImage.image = UIImage(systemName: tone.symbolName, withConfiguration: symbolConfig)
        glyphImage.tintColor = tone.accent
        glyphFallback.text = tone.fallbackGlyph
        glyphFallback.isHidden = glyphImage.image != nil
        glyphImage.isHidden = glyphImage.image == nil

        messageLabel.text = message
        accessibilityLabel = message
    }
}
