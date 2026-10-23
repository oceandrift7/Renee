import Flutter
import UIKit
import WebKit

/// Explicit, one-time browser session handoff for Renée's experimental
/// YouTube Music connection. This does not spoof an OAuth user-agent or
/// attempt to extract credentials from Safari / other applications.
///
/// All cookies stay within an ephemeral WKWebView until the user taps "Use
/// session" and confirms saving them into Renée's iOS Keychain-backed store.
final class ReneeYouTubeMusicBrowserBridge {
    static let channelName = "com.renee/ytmusic_auth_browser"

    private let channel: FlutterMethodChannel
    private let presenter: () -> UIViewController?
    private var activeBrowser: UINavigationController?

    init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
        self.presenter = presenter
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            DispatchQueue.main.async {
                guard let self else {
                    result(FlutterError(code: "UNAVAILABLE", message: "Browser bridge unavailable", details: nil))
                    return
                }
                guard call.method == "open" else {
                    result(FlutterMethodNotImplemented)
                    return
                }
                guard self.activeBrowser == nil, let host = self.presenter() else {
                    result(FlutterError(code: "BUSY", message: "Browser is already open or unavailable", details: nil))
                    return
                }
                let browser = ReneeYouTubeMusicBrowserController { [weak self] session in
                    guard let self, let active = self.activeBrowser else {
                        result(nil)
                        return
                    }
                    self.activeBrowser = nil
                    active.dismiss(animated: true) {
                        result(session)
                    }
                }
                let navigation = UINavigationController(rootViewController: browser)
                navigation.modalPresentationStyle = .pageSheet
                navigation.isModalInPresentation = true
                self.activeBrowser = navigation
                host.present(navigation, animated: true)
            }
        }
    }
}

/// A standalone native browser for `https://music.youtube.com`. Google can
/// deny account login inside a third-party WKWebView; this view deliberately
/// keeps the real WKWebView UA and reports that limitation instead of evading
/// Google's browser restrictions.
private final class ReneeYouTubeMusicBrowserController: UIViewController, WKNavigationDelegate {
    private let onFinish: ([String: Any]?) -> Void
    private var capturing = false
    private var webView: WKWebView!
    private let progress = UIActivityIndicatorView(style: .medium)
    private let message = UILabel()

    init(onFinish: @escaping ([String: Any]?) -> Void) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "YouTube Music"
        view.backgroundColor = .systemBackground

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Use session",
            style: .done,
            target: self,
            action: #selector(useSession)
        )

        message.text = "Google may block sign-in in embedded browsers. No credentials are saved until you choose Use session."
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .footnote)
        message.textColor = .secondaryLabel
        message.translatesAutoresizingMaskIntoConstraints = false

        let back = UIButton(type: .system)
        back.setTitle("Back", for: .normal)
        back.addTarget(self, action: #selector(goBack), for: .touchUpInside)

        let reload = UIButton(type: .system)
        reload.setTitle("Reload", for: .normal)
        reload.addTarget(self, action: #selector(reloadPage), for: .touchUpInside)

        let safari = UIButton(type: .system)
        safari.setTitle("Open Safari", for: .normal)
        safari.addTarget(self, action: #selector(openSafari), for: .touchUpInside)

        let toolbar = UIStackView(arrangedSubviews: [back, reload, safari, progress])
        toolbar.axis = .horizontal
        toolbar.distribution = .equalSpacing
        toolbar.alignment = .center
        toolbar.spacing = 12
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(webView)
        view.addSubview(message)
        view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -8),
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            message.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -8),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])

        guard let url = URL(string: "https://music.youtube.com/") else { return }
        webView.load(URLRequest(url: url))
    }

    @objc private func cancel() {
        guard !capturing else { return }
        onFinish(nil)
    }

    @objc private func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func openSafari() {
        let alert = UIAlertController(
            title: "Safari is separate",
            message: "Safari can open YouTube Music, but Renée cannot import Safari's Google session cookies. If Google blocks this browser, Safari does not automatically connect Renée.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Safari", style: .default) { _ in
            guard let url = URL(string: "https://music.youtube.com/") else { return }
            UIApplication.shared.open(url)
        })
        present(alert, animated: true)
    }

    private func showMessage(_ text: String) {
        let alert = UIAlertController(title: "YouTube Music", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // The page configuration is only read after confirming the top-level
    // browser is actually at music.youtube.com. No password fields are read.
    private static let sessionContextScript = """
    (function () {
      if (location.protocol !== 'https:' || location.hostname !== 'music.youtube.com') return null;
      try {
        const cfg = window.ytcfg;
        if (!cfg || typeof cfg.get !== 'function') return null;
        const field = function (name) {
          const value = cfg.get(name);
          return value === null || value === undefined ? null : String(value);
        };
        return {
          loggedIn: cfg.get('LOGGED_IN') === true,
          clientVersion: field('INNERTUBE_CLIENT_VERSION'),
          apiKey: field('INNERTUBE_API_KEY'),
          visitorData: field('VISITOR_DATA'),
          authUser: field('SESSION_INDEX') || '0',
          delegatedSessionId: field('DELEGATED_SESSION_ID')
        };
      } catch (_) {
        return null;
      }
    })()
    """

    @objc private func useSession() {
        guard !capturing else { return }
        guard let url = webView.url,
              url.scheme == "https",
              url.host == "music.youtube.com" else {
            showMessage("Return to music.youtube.com after finishing sign-in, then try again.")
            return
        }
        capturing = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        webView.evaluateJavaScript(Self.sessionContextScript) { [weak self] raw, _ in
            guard let self else { return }
            guard let config = raw as? [String: Any],
                  config["loggedIn"] as? Bool == true,
                  let version = config["clientVersion"] as? String,
                  !version.isEmpty else {
                self.finishCaptureWithError("YouTube Music has not confirmed a signed-in account in this browser. Google may block embedded login.")
                return
            }

            // Only YouTube-owned domain cookies may leave the ephemeral view.
            // Cookies for accounts.google.com / other web sites are excluded.
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] available in
                guard let self else { return }
                let allowedDomains: Set<String> = [
                    "youtube.com", ".youtube.com",
                    "music.youtube.com", ".music.youtube.com"
                ]
                let cookies = available.filter {
                    allowedDomains.contains($0.domain.lowercased())
                }
                var values = [String: String]()
                for cookie in cookies where cookie.name.count <= 128 && cookie.value.count <= 4096 {
                    values[cookie.name] = cookie.value
                }
                let signingCookies = ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"]
                guard signingCookies.contains(where: { values[$0]?.isEmpty == false }) else {
                    self.finishCaptureWithError("This browser has no usable YouTube Music signing cookie. The account might not be signed in, or Google refused the embedded session.")
                    return
                }

                let consent = UIAlertController(
                    title: "Connect this account?",
                    message: "Renée will save YouTube session cookies, not your password, encrypted on this iPhone to request music.youtube.com. These cookies can grant account access. You can disconnect in Settings. Login and music playback are experimental.",
                    preferredStyle: .alert
                )
                consent.addAction(UIAlertAction(title: "Not now", style: .cancel) { _ in
                    self.capturing = false
                    self.navigationItem.rightBarButtonItem?.isEnabled = true
                })
                consent.addAction(UIAlertAction(title: "Connect", style: .default) { _ in
                    let session: [String: Any] = [
                        "cookies": values,
                        "clientVersion": version,
                        "apiKey": config["apiKey"] ?? NSNull(),
                        "visitorData": config["visitorData"] ?? NSNull(),
                        "authUser": config["authUser"] as? String ?? "0",
                        "delegatedSessionId": config["delegatedSessionId"] ?? NSNull(),
                    ]
                    self.onFinish(session)
                })
                self.present(consent, animated: true)
            }
        }
    }

    private func finishCaptureWithError(_ detail: String) {
        capturing = false
        navigationItem.rightBarButtonItem?.isEnabled = true
        showMessage(detail)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress.startAnimating()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progress.stopAnimating()
        // Never forward raw server errors that could contain authentication URLs.
        message.text = "The page could not be loaded. Try reloading or check the network."
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        progress.stopAnimating()
        message.text = "YouTube Music is unavailable in this embedded browser."
    }
}
