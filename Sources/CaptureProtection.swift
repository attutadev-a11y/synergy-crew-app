import UIKit

// MARK: - Palette

extension UIColor {
    /// VOLTAGE volt-yellow #FFD400 — the team accent.
    static let voltageYellow = UIColor(red: 1.0, green: 212.0 / 255.0, blue: 0.0, alpha: 1.0)
}

// MARK: - Secure canvas host

/// Hosts content inside the private "secure canvas" UIKit renders password
/// fields into. That canvas is flagged as capture-excluded by the window
/// server, so anything parented into it stays fully visible on device but
/// comes out solid black in screenshots, screen recordings and mirroring.
///
/// The canvas lives in a private view hierarchy, so every step here is
/// validated. If a future iOS reshapes that hierarchy, `install(in:topAnchor:)`
/// returns `nil` and the caller must host its content normally: a
/// screenshottable app is a far better failure mode than a blank one.
final class SecureContentHost {

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

    /// True while the secure canvas still looks like a live, visible host.
    var isHealthy: Bool {
        guard let canvas = canvas else { return false }
        return field.isSecureTextEntry
            && field.window != nil
            && canvas.superview === field
            && !canvas.isHidden
            && canvas.alpha > 0.01
            && canvas.bounds.width > 1
            && canvas.bounds.height > 1
    }

    /// Installs the secure host as a subview of `container`, pinned full-bleed
    /// on the sides and bottom and to `topAnchor` up top (so callers keep their
    /// safe-area pinning).
    ///
    /// - Returns: the capture-excluded view to add content to, or `nil` when
    ///   the private hierarchy did not look the way we expect.
    @discardableResult
    func install(in container: UIView, topAnchor: NSLayoutYAxisAnchor? = nil) -> UIView? {
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

        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor ?? container.topAnchor),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // UIKit builds the canvas lazily — force a layout pass before looking.
        container.layoutIfNeeded()

        guard let canvas = Self.locateSecureCanvas(in: field) else {
            field.removeFromSuperview()
            return nil
        }

        // UIKit's own text-rendering subviews are dead weight; we own it now.
        canvas.subviews.forEach { $0.removeFromSuperview() }
        canvas.isUserInteractionEnabled = true
        canvas.backgroundColor = .clear
        canvas.isHidden = false
        canvas.alpha = 1
        canvas.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: field.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: field.bottomAnchor),
        ])

        self.canvas = canvas
        return canvas
    }

    /// Re-asserts the canvas geometry/visibility UIKit may reset behind our
    /// back (e.g. after a layout pass or a trip through the background).
    func enforceVisibility() {
        guard let canvas = canvas, canvas.superview === field else { return }
        if canvas.isHidden { canvas.isHidden = false }
        if canvas.alpha < 0.99 { canvas.alpha = 1 }
        if !field.isSecureTextEntry { field.isSecureTextEntry = true }
    }

    /// Tears the host back out, handing `content` back to the caller unparented.
    func uninstall(releasing content: UIView?) {
        content?.removeFromSuperview()
        canvas = nil
        field.removeFromSuperview()
    }

    /// Best-effort search for the capture-excluded canvas, newest-shape first.
    /// Every candidate must be a real child of the field, or we reject it.
    private static func locateSecureCanvas(in field: UITextField) -> UIView? {
        let byClassName = field.subviews.first {
            String(describing: type(of: $0)).contains("CanvasView")
        }
        let byLayerDelegate = field.layer.sublayers?.first?.delegate as? UIView
        let candidates: [UIView?] = [byClassName, byLayerDelegate, field.subviews.first]

        for case let candidate? in candidates where candidate !== field && candidate.superview === field {
            return candidate
        }
        return nil
    }
}

// MARK: - Capture notice overlay

/// Full-bleed charcoal curtain shown when the screen is being recorded or a
/// screenshot was just taken.
final class CaptureNoticeView: UIView {

    private let glyphContainer = UIView()
    private let glyphImage = UIImageView()
    private let glyphFallback = UILabel()
    private let messageLabel = UILabel()

    init(message: String) {
        super.init(frame: .zero)
        backgroundColor = .voltageCharcoal
        isAccessibilityElement = true
        accessibilityViewIsModal = true
        translatesAutoresizingMaskIntoConstraints = false

        glyphContainer.translatesAutoresizingMaskIntoConstraints = false
        glyphContainer.backgroundColor = UIColor.voltageYellow.withAlphaComponent(0.12)
        glyphContainer.layer.cornerRadius = 44
        glyphContainer.layer.borderWidth = 1
        glyphContainer.layer.borderColor = UIColor.voltageYellow.withAlphaComponent(0.45).cgColor

        glyphImage.translatesAutoresizingMaskIntoConstraints = false
        glyphImage.tintColor = .voltageYellow
        glyphImage.contentMode = .scaleAspectFit
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 38, weight: .semibold)
        glyphImage.image = UIImage(systemName: "lock.fill", withConfiguration: symbolConfig)

        // If the symbol is ever unavailable, a plain padlock still reads.
        glyphFallback.translatesAutoresizingMaskIntoConstraints = false
        glyphFallback.text = "\u{1F512}"
        glyphFallback.font = .systemFont(ofSize: 38)
        glyphFallback.textAlignment = .center
        glyphFallback.isHidden = glyphImage.image != nil
        glyphImage.isHidden = glyphImage.image == nil

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.text = message
        messageLabel.textColor = UIColor(white: 0.96, alpha: 1)
        messageLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        accessibilityLabel = message

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMessage(_ text: String) {
        messageLabel.text = text
        accessibilityLabel = text
    }
}
