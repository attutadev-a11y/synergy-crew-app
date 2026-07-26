import UIKit
import WebKit

/// Full-screen wrapper around the 3134S crew dashboard.
///
/// Team content is capture-protected three ways:
///  1. the web view lives inside a secure canvas, so screenshots and screen
///     recordings render it black while it stays visible on device,
///  2. an on-screen curtain while a recording/mirroring session is live,
///  3. a brief curtain flash whenever a screenshot is taken.
final class CrewViewController: UIViewController {

    private static let dashboardURL = URL(string: "https://team-3134s.web.app/app.html?source=app")!

    /// Hosts that stay inside the app; everything else opens in Safari.
    private static let teamHosts: Set<String> = [
        "team-3134s.web.app",
        "team-3134s.firebaseapp.com",
    ]

    private static let recordingMessage = "Screen recording detected — 3134S content hidden"
    private static let screenshotMessage = "Screenshots are disabled for team content"

    private var webView: WKWebView!
    private let refreshControl = UIRefreshControl()

    /// Secure (capture-excluded) host for the web view. Falls back to plain
    /// hosting if UIKit's private hierarchy ever stops looking familiar.
    private let secureHost = SecureContentHost()
    private var isCaptureProtected = false

    private var noticeView: CaptureNoticeView?
    private var screenshotDismissWork: DispatchWorkItem?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    deinit {
        NotificationCenter.default.removeObserver(self)
        screenshotDismissWork?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .voltageCharcoal

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .voltageCharcoal
        webView.scrollView.backgroundColor = .voltageCharcoal
        // The webview's top is pinned below the status bar, so no automatic
        // safe-area content insets are wanted inside the scroll view itself.
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        refreshControl.tintColor = .voltageYellow
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        attachWebView()
        registerCaptureObservers()
        loadDashboard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncCaptureState()
        // Give UIKit one full run loop with real bounds before judging the
        // secure canvas, then re-check once more a beat later.
        verifySecureHostOrFallBack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.verifySecureHostOrFallBack()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if isCaptureProtected {
            secureHost.enforceVisibility()
        }
        if let notice = noticeView {
            view.bringSubviewToFront(notice)
        }
    }

    // MARK: - Web view hosting

    /// Parents the web view inside the secure canvas when available, otherwise
    /// directly in the root view. Either way the top hugs the safe area so
    /// content never under-laps the status bar, and the sides/bottom stay
    /// full-bleed for the edge-to-edge look.
    private func attachWebView() {
        if let canvas = secureHost.install(in: view, topAnchor: view.safeAreaLayoutGuide.topAnchor) {
            canvas.addSubview(webView)
            pinWebView(to: canvas, top: canvas.topAnchor)
            isCaptureProtected = true
        } else {
            view.addSubview(webView)
            pinWebView(to: view, top: view.safeAreaLayoutGuide.topAnchor)
            isCaptureProtected = false
        }
    }

    private func pinWebView(to container: UIView, top: NSLayoutYAxisAnchor) {
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: top),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Never ship a blank app: if the secure canvas is not actually presenting
    /// our content, drop the protection and host the web view normally.
    private func verifySecureHostOrFallBack() {
        // Only judge the canvas once there is a real, laid-out window to judge
        // it in — an early check would fall back for no reason and quietly
        // give up the protection.
        guard isCaptureProtected,
              view.window != nil,
              view.bounds.width > 1,
              view.bounds.height > 1
        else { return }

        view.layoutIfNeeded()

        let healthy = secureHost.isHealthy
            && webView.window != nil
            && !webView.isHidden
            && webView.alpha > 0.01
            && webView.bounds.width > 1
            && webView.bounds.height > 1
        guard !healthy else { return }

        isCaptureProtected = false
        secureHost.uninstall(releasing: webView)
        view.addSubview(webView)
        pinWebView(to: view, top: view.safeAreaLayoutGuide.topAnchor)
        if let notice = noticeView {
            view.bringSubviewToFront(notice)
        }
        view.setNeedsLayout()
    }

    // MARK: - Loading

    private func loadDashboard() {
        webView.load(URLRequest(url: Self.dashboardURL))
    }

    @objc private func handleRefresh() {
        if webView.url != nil {
            webView.reload()
        } else {
            loadDashboard()
        }
    }

    private static func isTeamURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return teamHosts.contains(host)
    }

    // MARK: - Capture detection

    private func registerCaptureObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleCapturedDidChange),
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleScreenshotTaken),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// True while the screen is being recorded, mirrored or AirPlayed.
    private var isScreenCaptured: Bool {
        (view.window?.screen ?? UIScreen.main).isCaptured
    }

    @objc private func handleCapturedDidChange() {
        syncCaptureState()
    }

    @objc private func handleDidBecomeActive() {
        // capturedDidChange can fire while we are backgrounded, so re-read the
        // truth on the way back in — and re-check the secure canvas too.
        syncCaptureState()
        verifySecureHostOrFallBack()
    }

    private func syncCaptureState() {
        if isScreenCaptured {
            screenshotDismissWork?.cancel()
            screenshotDismissWork = nil
            presentNotice(message: Self.recordingMessage)
        } else if screenshotDismissWork == nil {
            dismissNotice()
        }
    }

    @objc private func handleScreenshotTaken() {
        // A live recording already has the curtain up with its own message.
        guard !isScreenCaptured else { return }

        presentNotice(message: Self.screenshotMessage)

        screenshotDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.screenshotDismissWork = nil
            guard !self.isScreenCaptured else { return }
            self.dismissNotice()
        }
        screenshotDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Notice overlay

    /// The curtain deliberately lives outside the secure canvas so it shows up
    /// in the recording itself — the viewer sees the notice, not the content.
    private func presentNotice(message: String) {
        if let notice = noticeView {
            notice.setMessage(message)
            view.bringSubviewToFront(notice)
            notice.alpha = 1
            return
        }

        let notice = CaptureNoticeView(message: message)
        notice.alpha = 0
        view.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: view.topAnchor),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            notice.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        noticeView = notice
        view.layoutIfNeeded()

        UIView.animate(withDuration: 0.18) { notice.alpha = 1 }
        UIAccessibility.post(notification: .screenChanged, argument: notice)
    }

    private func dismissNotice() {
        guard let notice = noticeView else { return }
        noticeView = nil
        UIView.animate(
            withDuration: 0.28,
            animations: { notice.alpha = 0 },
            completion: { _ in notice.removeFromSuperview() }
        )
    }
}

// MARK: - WKNavigationDelegate

extension CrewViewController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        // Non-web schemes (mailto:, tel:, sms:, facetime:, …) go to the system.
        if scheme != "http" && scheme != "https" && scheme != "about" && scheme != "blob" && scheme != "data" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // Tapped links that leave the team domains open in Safari.
        if navigationAction.navigationType == .linkActivated,
           (scheme == "http" || scheme == "https"),
           !Self.isTeamURL(url) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        // A finished load is a good moment to confirm the canvas still holds us.
        verifySecureHostOrFallBack()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
    }
}

// MARK: - WKUIDelegate

extension CrewViewController: WKUIDelegate {

    /// target="_blank" handling: team links stay in the app, everything else opens in Safari.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if Self.isTeamURL(url) {
            webView.load(URLRequest(url: url))
        } else {
            UIApplication.shared.open(url)
        }
        return nil
    }
}
