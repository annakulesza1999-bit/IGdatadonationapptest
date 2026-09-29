import SwiftUI
import UIKit
import WebKit

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler? = nil) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class InstagramWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published private(set) var status = "Ready to open Instagram"
    @Published private(set) var canGoBack = false
    @Published private(set) var isLoading = false
    @Published private(set) var candidateCount = 0
    @Published private(set) var visibleCount = 0
    @Published private(set) var recorderReady = false
    @Published private(set) var pageRecording = false
    @Published private(set) var metadataCount = 0
    @Published private(set) var recorderError: String?
    @Published private(set) var pageObscured = false

    weak var store: DonationStore?
    let webView: WKWebView
    private var metadataByCode: [String: [String: Any]] = [:]
    private var codesByMediaKey: [String: Set<String>] = [:]
    private var codesByAccount: [String: Set<String>] = [:]
    private var unmatchedObservations: [String: [String: Any]] = [:]
    private var recordingAllowed: Bool { store?.isRecording == true && !pageObscured }

    override init() {
        let controller = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let donationHandler = WeakMessageHandler()
        let metadataHandler = WeakMessageHandler()
        let observerURL = Bundle.main.url(forResource: "FeedObserver", withExtension: "js")
        let observerSource = observerURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if let observerSource {
            controller.addUserScript(WKUserScript(source: observerSource, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: .defaultClient))
            controller.add(donationHandler, contentWorld: .defaultClient, name: "donation")
        }
        let metadataURL = Bundle.main.url(forResource: "FeedMetadata", withExtension: "js")
        let metadataSource = metadataURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if let metadataSource {
            controller.addUserScript(WKUserScript(source: metadataSource, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
            controller.add(metadataHandler, contentWorld: .page, name: "feedMetadata")
        }

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        donationHandler.target = self
        metadataHandler.target = self
        if observerSource == nil {
            status = "Recording script missing from the app bundle"
            recorderError = status
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func start() {
        guard webView.url == nil,
              let url = URL(string: "https://www.instagram.com/") else { return }
        webView.load(URLRequest(url: url))
    }

    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }

    func setRecording(_ enabled: Bool) {
        let desired = enabled && !pageObscured ? "true" : "false"
        let script = "typeof window.__instagramCaptureSetEnabled === 'function' " +
            "? window.__instagramCaptureSetEnabled(\(desired)) " +
            ": (window.__feedWindowEnabled = \(desired))"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                let message = "Could not set page recording: \(error.localizedDescription)"
                self.status = message
                self.recorderError = message
            }
        }
    }

    func setPageObscured(_ obscured: Bool) {
        pageObscured = obscured
        if obscured { pageRecording = false }
        setRecording(store?.isRecording == true)
    }

    func clearLogin() {
        setRecording(false)
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.status = "Browser sign-in cleared"
                if let url = URL(string: "https://www.instagram.com/") {
                    self?.webView.load(URLRequest(url: url))
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard ["donation", "feedMetadata"].contains(message.name), message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.`protocol` == "https",
              ["instagram.com", "www.instagram.com"].contains(
                message.frameInfo.securityOrigin.host.lowercased()
              ),
              ["instagram.com", "www.instagram.com"].contains(
                webView.url?.host?.lowercased() ?? ""
              ),
              let payload = message.body as? [String: Any] else { return }
        if message.name == "feedMetadata" {
            guard payload["event"] as? String == "metadata",
                  let permalink = payload["permalink"] as? String,
                  let code = postCode(permalink), metadataByCode.count < 3_000 else { return }
            metadataByCode[code] = payload
            for key in validatedKeys(payload["mediaKeys"]) {
                codesByMediaKey[key, default: []].insert(code)
            }
            if let account = payload["account"] as? String,
               account.range(of: "^[A-Za-z0-9._]{1,30}$", options: .regularExpression) != nil {
                codesByAccount[account.lowercased(), default: []].insert(code)
            }
            metadataCount = metadataByCode.count
            if recordingAllowed {
                if let post = store?.posts.first(where: {
                       $0.permalink == permalink &&
                       ($0.caption.isEmpty || $0.account == "Unknown account" ||
                        $0.relationship == .unknown)
                   }) {
                    let observation: [String: Any] = ["event": "relationship",
                        "observationId": post.observationId, "permalink": permalink]
                    store?.record(enriched(observation, with: payload))
                }
                var matchedIDs: [String] = []
                for (id, observation) in unmatchedObservations {
                    if let metadata = metadataFor(observation) {
                        var update = enriched(observation, with: metadata)
                        update["event"] = "relationship"
                        store?.record(update)
                        matchedIDs.append(id)
                    }
                }
                for id in matchedIDs { unmatchedObservations.removeValue(forKey: id) }
            }
            return
        }
        if payload["event"] as? String == "status" {
            let expected = recordingAllowed
            pageRecording = payload["enabled"] as? Bool ?? false
            recorderReady = true
            candidateCount = max(0, min(payload["candidates"] as? Int ?? 0, 10_000))
            visibleCount = max(0, min(payload["visible"] as? Int ?? 0, 100))
            let surface = payload["surface"] as? String ?? "Other page"
            if let failure = payload["error"] as? String, !failure.isEmpty {
                pageRecording = false
                let message = "Page recorder error: \(String(failure.prefix(160)))"
                recorderError = message
                status = message
                return
            }
            if pageRecording != expected { setRecording(expected) }
            if expected && pageRecording { recorderError = nil }
            if !expected {
                status = "Recorder paused · \(surface)"
            } else if !pageRecording {
                status = "Waiting for page recorder · \(surface)"
            } else {
                status = candidateCount == 0
                    ? "Recorder on · \(surface) · no post cards found"
                    : "Recorder on · \(candidateCount) cards found · \(metadataCount) feed IDs"
            }
            return
        }
        guard recordingAllowed else { return }
        let metadata = metadataFor(payload)
        let merged = metadata.map { enriched(payload, with: $0) } ?? payload
        if (payload["permalink"] as? String ?? "").isEmpty && metadata == nil,
           let id = payload["observationId"] as? String, UUID(uuidString: id) != nil {
            // Later visible-time messages are intentionally small. Keep the
            // identity keys from the impression until matching metadata arrives.
            let hasMediaKey = !validatedKeys(payload["mediaKeys"]).isEmpty
            let hasAccount = !(payload["account"] as? String ?? "").isEmpty
            let hasDuration = (payload["videoDuration"] as? Double ?? 0) > 0
            let hasCaption = (payload["caption"] as? String ?? "").count >= 12
            if (hasMediaKey || (hasAccount && (hasDuration || hasCaption))) &&
                unmatchedObservations.count < 1_000 {
                unmatchedObservations[id] = payload
            }
        } else if let id = payload["observationId"] as? String {
            unmatchedObservations.removeValue(forKey: id)
        }
        store?.record(merged)
    }

    private func validatedKeys(_ raw: Any?) -> [String] {
        guard let values = raw as? [String] else { return [] }
        return Array(Set(values.prefix(24).filter {
            $0.range(of: "^[A-Za-z0-9._-]{8,150}$", options: .regularExpression) != nil
        }))
    }

    private func metadataFor(_ payload: [String: Any]) -> [String: Any]? {
        if let permalink = payload["permalink"] as? String,
           let code = postCode(permalink) {
            return metadataByCode[code]
        }
        let mediaMatches = Set(validatedKeys(payload["mediaKeys"]).flatMap {
            codesByMediaKey[$0] ?? []
        })
        let account = payload["account"] as? String ?? ""
        var matches = Set(mediaMatches.filter { code in
            let candidateAccount = metadataByCode[code]?["account"] as? String ?? ""
            return account.isEmpty || candidateAccount.isEmpty ||
                account.caseInsensitiveCompare(candidateAccount) == .orderedSame
        })
        if matches.isEmpty, payload["isVideo"] as? Bool == true,
           let duration = payload["videoDuration"] as? Double, duration > 0,
           !account.isEmpty {
            matches = Set((codesByAccount[account.lowercased()] ?? []).filter { code in
                let observationSurface = payload["surface"] as? String
                guard let candidate = metadataByCode[code],
                      candidate["isVideo"] as? Bool == true,
                      let candidateSurface = candidate["surface"] as? String,
                      candidateSurface == observationSurface,
                      let candidateDuration = candidate["videoDuration"] as? Double,
                      abs(candidateDuration - duration) < 0.75 else { return false }
                let candidateLink = candidate["permalink"] as? String ?? ""
                let observationId = payload["observationId"] as? String ?? ""
                return store?.posts.contains(where: {
                    $0.permalink == candidateLink && $0.observationId != observationId
                }) != true
            })
        }
        if matches.isEmpty, !account.isEmpty,
           let caption = payload["caption"] as? String,
           caption.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 {
            let wanted = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            matches = Set((codesByAccount[account.lowercased()] ?? []).filter { code in
                guard let candidate = metadataByCode[code],
                      let candidateCaption = candidate["caption"] as? String,
                      candidateCaption.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(wanted) == .orderedSame else { return false }
                let candidateLink = candidate["permalink"] as? String ?? ""
                let observationId = payload["observationId"] as? String ?? ""
                return store?.posts.contains(where: {
                    $0.permalink == candidateLink && $0.observationId != observationId
                }) != true
            })
        }
        guard matches.count == 1, let code = matches.first,
              let metadata = metadataByCode[code] else { return nil }
        let metadataAccount = metadata["account"] as? String ?? ""
        guard account.isEmpty || metadataAccount.isEmpty ||
              account.caseInsensitiveCompare(metadataAccount) == .orderedSame else { return nil }
        return metadata
    }

    private func enriched(_ payload: [String: Any], with metadata: [String: Any]) -> [String: Any] {
        var merged = payload
        if (payload["permalink"] as? String ?? "").isEmpty {
            merged["permalink"] = metadata["permalink"]
        }
        if (payload["account"] as? String ?? "").isEmpty {
            merged["account"] = metadata["account"]
        }
        if let relation = metadata["relationship"] as? String,
           relation == "Followed" || relation == "Not followed" {
            merged["relationship"] = relation
        }
        if metadata["label"] as? String == "Sponsored" {
            merged["label"] = "Sponsored"
        } else if payload["label"] as? String == "Post",
                  metadata["label"] as? String == "Suggested" {
            merged["label"] = "Suggested"
        }
        if metadata["isVideo"] as? Bool == true { merged["isVideo"] = true }
        if let duration = metadata["videoDuration"] { merged["videoDuration"] = duration }
        if let caption = metadata["caption"] { merged["caption"] = caption }
        if let hashtags = metadata["hashtags"] { merged["hashtags"] = hashtags }
        return merged
    }

    private func postCode(_ permalink: String) -> String? {
        guard let url = URL(string: permalink), url.scheme == "https",
              ["instagram.com", "www.instagram.com"].contains(url.host?.lowercased() ?? "") else {
            return nil
        }
        let path = url.pathComponents.filter { $0 != "/" }
        return path.count == 2 && ["p", "reel"].contains(path[0]) ? path[1] : nil
    }

    private func isInstagram(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "instagram.com" || host.hasSuffix(".instagram.com")
    }

    private func openExternalLink(_ url: URL, from action: WKNavigationAction) {
        let host = url.host?.lowercased() ?? ""
        let isLoginSync = (host == "facebook.com" || host.hasSuffix(".facebook.com")) &&
            url.path.hasPrefix("/instagram/login_sync")
        // Instagram can request login synchronization during page load. Open a
        // separate browser only for a link the person deliberately tapped.
        guard !isLoginSync, action.navigationType == .linkActivated else { return }
        UIApplication.shared.open(url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "about" || url.scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        guard url.scheme?.lowercased() == "https" else {
            decisionHandler(.cancel)
            return
        }
        if isInstagram(url) {
            decisionHandler(.allow)
        } else {
            openExternalLink(url, from: navigationAction)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        status = "Loading Instagram…"
        recorderReady = false
        pageRecording = false
        candidateCount = 0
        metadataCount = 0
        metadataByCode.removeAll()
        codesByMediaKey.removeAll()
        codesByAccount.removeAll()
        unmatchedObservations.removeAll()
        canGoBack = webView.canGoBack
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        canGoBack = webView.canGoBack
        setRecording(recordingAllowed)
        if !recorderReady { status = "Page loaded · waiting for post cards" }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        status = "Instagram's browser process restarted · reloading"
        recorderReady = false
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        isLoading = false
        status = "Could not load Instagram: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        status = "Page error: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if isInstagram(url) {
                webView.load(URLRequest(url: url))
            } else if url.scheme?.lowercased() == "https" {
                openExternalLink(url, from: navigationAction)
            }
        }
        return nil
    }
}

struct InstagramWebView: UIViewRepresentable {
    let session: InstagramWebSession

    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
