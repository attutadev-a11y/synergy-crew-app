import UIKit
import WebKit

/// Full-screen wrapper around the 3134S crew dashboard.
final class CrewViewController: UIViewController {

    private static let dashboardURL = URL(string: "https://team-3134s.web.app/crew.html?source=app")!

    /// Hosts that stay inside the app; everything else opens in Safari.
    private static let teamHosts: Set<String> = [
        "team-3134s.web.app",
        "team-3134s.firebaseapp.com",
    ]

    private var webView: WKWebView!
    private let refreshControl = UIRefreshControl()

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

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

        refreshControl.tintColor = UIColor(red: 1.0, green: 212.0 / 255.0, blue: 0.0, alpha: 1.0)
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        view.addSubview(webView)

        // Top hugs the safe area so content never under-laps the status bar;
        // the view's charcoal background fills the strip behind clock/battery.
        // Leading/trailing/bottom stay full-bleed for the edge-to-edge look.
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        loadDashboard()
    }

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
