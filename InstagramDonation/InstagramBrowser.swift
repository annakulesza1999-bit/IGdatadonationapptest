import SwiftUI
import UIKit
import WebKit

// Only allowlisted technical events enter the log. No free-form page text or IDs.
enum CaptureDiagnosticEvent: String, Codable {
    case started = "Diagnostic session started"
    case paused = "Recording suspended while app screen or background is active"
    case resumed = "Recording resumed; retrying cached post identities"
    case navigation = "Page navigation; temporary matching cache reset"
    case readerReady = "Metadata reader started"
    case readerMissing = "Metadata reader missing from app bundle"
    case observerMissing = "Page observer missing from app bundle"
    case observerFailed = "Page observer reported an error"
    case bridgeFailed = "Could not set page recording state"
    case parseFailed = "Metadata response could not be parsed"
    case scanFailed = "Preloaded metadata could not be parsed or scanned"
    case scanLimited = "Metadata scan reached its processing limit"
    case noIdentity = "Missing link: no usable identification clues yet"
    case metadataMissing = "Missing link: no matching metadata yet"
    case ambiguous = "Missing link: multiple candidate posts; no link assigned"
    case accountMismatch = "Missing link: candidate author conflicts with observed author"
    case matched = "Missing post link resolved"
    case pendingEvicted = "Oldest unresolved identity removed from bounded cache"
    case metadataEvicted = "Oldest metadata removed from bounded cache"
    case retryFinished = "Cached identities retried; recovered count"
    case navigationFailed = "Instagram page navigation failed"
    case processRestart = "Web content process terminated; reloading"
}

struct CaptureDiagnosticEntry: Identifiable, Codable {
    let id: UUID
    let at: Date
    let event: CaptureDiagnosticEvent
    let count: Int?
}

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
    @Published private(set) var diagnosticEntries: [CaptureDiagnosticEntry] = []
    @Published private(set) var diagnosticLogging = true
    @Published private(set) var pendingLinkCount = 0
    private var diagnosticTimes: [CaptureDiagnosticEvent: Date] = [:]
    private var pendingReasons: [String: CaptureDiagnosticEvent] = [:]
    private var pendingOrder: [String] = []
    private var metadataOrder: [String] = []
    private var pendingIdentityRetry: Task<Void, Never>?
    private var diagnosticURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("instagram-capture-diagnostics.json")
    }

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
        clearDiagnostics()
        log(.started)
        donationHandler.target = self
        metadataHandler.target = self
        if observerSource == nil {
            status = "Recording script missing from the app bundle"
            recorderError = status
            log(.observerMissing)
        }
        if metadataSource == nil { log(.readerMissing) }

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
        if desired == "true" { retryPendingIdentities() }
        let script = "typeof window.__instagramCaptureSetEnabled === 'function' " +
            "? window.__instagramCaptureSetEnabled(\(desired)) " +
            ": (window.__feedWindowEnabled = \(desired))"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                let message = "Could not set page recording: \(error.localizedDescription)"
                self.status = message
                self.recorderError = message
                self.log(.bridgeFailed)
            }
        }
    }

    func setPageObscured(_ obscured: Bool) {
        let changed = pageObscured != obscured
        pageObscured = obscured
        if changed { log(obscured ? .paused : .resumed) }
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
            if payload["event"] as? String == "metadata_diagnostic" {
                switch payload["code"] as? String {
                case "reader_ready": log(.readerReady)
                case "response_parse_failed": log(.parseFailed)
                case "parse_or_scan_failed": log(.scanFailed)
                case "scan_limit": log(.scanLimited)
                default: break
                }
                return
            }
            guard payload["event"] as? String == "metadata",
                  let permalink = payload["permalink"] as? String,
                  let code = postCode(permalink) else { return }
            if metadataByCode[code] == nil {
                if metadataOrder.count >= 3_000 {
                    removeMetadata(metadataOrder.removeFirst())
                    log(.metadataEvicted)
                }
                metadataOrder.append(code)
            } else { removeMetadata(code) }
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
                scheduleIdentityRetry()
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
                log(.observerFailed)
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
        guard let event = payload["event"] as? String,
              ["impression", "visible", "watch", "interaction", "relationship"].contains(event),
              let rawID = payload["observationId"] as? String,
              let observationUUID = UUID(uuidString: rawID) else { return }
        let id = observationUUID.uuidString
        if event == "relationship" {
            let link = payload["permalink"] as? String ?? ""
            guard store?.posts.contains(where: {
                $0.observationId == id || (!link.isEmpty && $0.permalink == link)
            }) == true else { return }
        }
        // Retain identification fields only. Never cache seconds, actions or comment text
        // for replay: retries must enrich a record without counting anything twice.
        var identity = unmatchedObservations[id] ?? [:]
        for key in ["observationId", "permalink", "mediaKeys", "account", "caption", "hashtags",
                    "videoDuration", "isVideo", "surface", "label", "relationship"] {
            if let value = payload[key] {
                if let text = value as? String, text.isEmpty, identity[key] != nil { continue }
                identity[key] = value
            }
        }
        identity["observationId"] = id
        // A prior recovery can be reused for the small visible-time/watch messages.
        if (identity["permalink"] as? String ?? "").isEmpty,
           let saved = store?.posts.first(where: { $0.observationId == id }), !saved.permalink.isEmpty {
            identity["permalink"] = saved.permalink
        }
        let resolution = resolveMetadata(identity)
        var merged = payload
        merged["observationId"] = id
        if let link = identity["permalink"] as? String, !link.isEmpty { merged["permalink"] = link }
        if let metadata = resolution.metadata { merged = enriched(merged, with: metadata) }
        if (merged["permalink"] as? String ?? "").isEmpty {
            rememberPending(id, identity: identity, reason: resolution.reason)
        } else {
            if unmatchedObservations[id] != nil { log(.matched) }
            removePending(id)
        }
        store?.record(merged)
    }

    private func rememberPending(_ id: String, identity: [String: Any], reason: CaptureDiagnosticEvent) {
        if unmatchedObservations[id] == nil {
            if pendingOrder.count >= 1_000 {
                removePending(pendingOrder[0])
                log(.pendingEvicted)
            }
            pendingOrder.append(id)
        }
        unmatchedObservations[id] = identity
        if pendingReasons[id] != reason { log(reason) }
        pendingReasons[id] = reason
        if pendingLinkCount != pendingOrder.count { pendingLinkCount = pendingOrder.count }
    }

    private func removePending(_ id: String) {
        unmatchedObservations.removeValue(forKey: id)
        pendingReasons.removeValue(forKey: id)
        pendingOrder.removeAll { $0 == id }
        if pendingLinkCount != pendingOrder.count { pendingLinkCount = pendingOrder.count }
    }

    private func scheduleIdentityRetry() {
        // One response can contain hundreds of posts. Coalesce its callbacks so
        // the main thread does not rematch the entire pending cache for each one.
        guard pendingIdentityRetry == nil else { return }
        pendingIdentityRetry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            guard let self else { return }
            self.pendingIdentityRetry = nil
            self.retryPendingIdentities()
        }
    }

    private func retryPendingIdentities() {
        pendingIdentityRetry?.cancel()
        pendingIdentityRetry = nil
        guard recordingAllowed else { return }
        var recovered = 0
        for id in pendingOrder {
            guard let identity = unmatchedObservations[id] else { continue }
            // A deleted result must never be recreated by a metadata retry.
            guard store?.posts.contains(where: { $0.observationId == id }) == true else {
                removePending(id)
                continue
            }
            let resolution = resolveMetadata(identity)
            if let metadata = resolution.metadata {
                var update = enriched(identity, with: metadata)
                update["event"] = "relationship"
                store?.record(update)
                removePending(id)
                recovered += 1
            } else if pendingReasons[id] != resolution.reason {
                pendingReasons[id] = resolution.reason
                log(resolution.reason)
            }
        }
        if recovered > 0 { log(.retryFinished, count: recovered) }
    }

    private func removeMetadata(_ code: String) {
        guard let old = metadataByCode.removeValue(forKey: code) else { return }
        for key in validatedKeys(old["mediaKeys"]) {
            codesByMediaKey[key]?.remove(code)
            if codesByMediaKey[key]?.isEmpty == true { codesByMediaKey.removeValue(forKey: key) }
        }
        if let account = old["account"] as? String {
            let key = account.lowercased()
            codesByAccount[key]?.remove(code)
            if codesByAccount[key]?.isEmpty == true { codesByAccount.removeValue(forKey: key) }
        }
    }

    private func log(_ event: CaptureDiagnosticEvent, count: Int? = nil) {
        guard diagnosticLogging else { return }
        let now = Date()
        // Rate limit repeating event types, including missing-link reports across posts.
        if let previous = diagnosticTimes[event], now.timeIntervalSince(previous) < 5 { return }
        diagnosticTimes[event] = now
        diagnosticEntries.append(CaptureDiagnosticEntry(id: UUID(), at: now, event: event, count: count))
        if diagnosticEntries.count > 250 { diagnosticEntries.removeFirst(diagnosticEntries.count - 250) }
    }

    func setDiagnosticLogging(_ enabled: Bool) {
        diagnosticLogging = enabled
        if !enabled { clearDiagnostics() } else { log(.started) }
    }

    func clearDiagnostics() {
        diagnosticEntries.removeAll()
        diagnosticTimes.removeAll()
        try? FileManager.default.removeItem(at: diagnosticURL)
    }

    func exportDiagnostics() throws -> URL {
        struct Report: Encodable {
            let formatVersion: Int
            let appVersion: String
            let exportedAt: Date
            let pendingIdentities: Int
            let metadataEntries: Int
            let entries: [CaptureDiagnosticEntry]
        }
        let report = Report(formatVersion: 1,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            exportedAt: Date(), pendingIdentities: pendingLinkCount,
            metadataEntries: metadataCount, entries: diagnosticEntries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: diagnosticURL, options: [.atomic, .completeFileProtection])
        return diagnosticURL
    }

    private func validatedKeys(_ raw: Any?) -> [String] {
        guard let values = raw as? [String] else { return [] }
        return Array(Set(values.prefix(24).filter {
            $0.range(of: "^[A-Za-z0-9._-]{8,150}$", options: .regularExpression) != nil
        }))
    }

    private func resolveMetadata(_ payload: [String: Any]) -> (metadata: [String: Any]?, reason: CaptureDiagnosticEvent) {
        if let permalink = payload["permalink"] as? String,
           let code = postCode(permalink) {
            return (metadataByCode[code], .metadataMissing)
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
        if matches.count > 1 { return (nil, .ambiguous) }
        guard let code = matches.first, let metadata = metadataByCode[code] else {
            if !mediaMatches.isEmpty { return (nil, .accountMismatch) }
            let hasClues = !validatedKeys(payload["mediaKeys"]).isEmpty ||
                (!account.isEmpty && ((payload["videoDuration"] as? Double ?? 0) > 0 ||
                    (payload["caption"] as? String ?? "").count >= 12))
            return (nil, hasClues ? .metadataMissing : .noIdentity)
        }
        let metadataAccount = metadata["account"] as? String ?? ""
        guard account.isEmpty || metadataAccount.isEmpty ||
              account.caseInsensitiveCompare(metadataAccount) == .orderedSame else { return (nil, .accountMismatch) }
        return (metadata, .matched)
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
        log(.navigation, count: pendingLinkCount)
        pendingIdentityRetry?.cancel()
        pendingIdentityRetry = nil
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
        pendingReasons.removeAll()
        pendingOrder.removeAll()
        metadataOrder.removeAll()
        pendingLinkCount = 0
        canGoBack = webView.canGoBack
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        canGoBack = webView.canGoBack
        setRecording(recordingAllowed)
        if !recorderReady { status = "Page loaded · waiting for post cards" }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log(.processRestart)
        status = "Instagram's browser process restarted · reloading"
        recorderReady = false
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        isLoading = false
        status = "Could not load Instagram: \(error.localizedDescription)"
        log(.navigationFailed)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        status = "Page error: \(error.localizedDescription)"
        log(.navigationFailed)
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
