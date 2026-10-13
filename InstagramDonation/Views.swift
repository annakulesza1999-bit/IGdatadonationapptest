import SwiftUI
import UIKit
import Combine

private enum Theme {
    static let background = Color(red: 0.965, green: 0.96, blue: 0.945)
    static let ink = Color(red: 0.10, green: 0.14, blue: 0.20)
    static let accent = Color(red: 0.87, green: 0.34, blue: 0.29)
    static let paleAccent = Color(red: 1.0, green: 0.91, blue: 0.87)
    static let muted = Color(red: 0.42, green: 0.45, blue: 0.48)
}

struct RootView: View {
    @ObservedObject var store: DonationStore
    @AppStorage("homeFeedConsent") private var hasConsented = false
    @AppStorage("captureConsentVersion") private var captureConsentVersion = 0
    @State private var showingPreview = false

    var body: some View {
        Group {
            if hasConsented && captureConsentVersion >= 4 {
                BrowserFlow(store: store, hasConsented: $hasConsented)
            } else {
                WelcomeScreen(
                    onContinue: {
                        captureConsentVersion = 4
                        hasConsented = true
                        store.setRecording(true)
                    },
                    onPreview: { showingPreview = true }
                )
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showingPreview) { SampleResultsScreen() }
    }
}

private struct WelcomeScreen: View {
    let onContinue: () -> Void
    let onPreview: () -> Void
    @State private var understands = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title2).foregroundStyle(Theme.accent)
                    Text("INSTAGRAM CAPTURE")
                        .font(.caption.bold()).tracking(2.2)
                }
                .padding(.top, 30)

                Text("See your feed.\nKeep your data.")
                    .font(.system(size: 39, weight: .bold, design: .rounded))
                    .tracking(-1.5)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Browse Instagram’s mobile site inside the app. Review posts you saw, time on screen, video playback, and the actions you took.")
                    .font(.body).foregroundStyle(Theme.muted)

                VStack(alignment: .leading, spacing: 16) {
                    feature("eye", "What is saved", "Posts, visible time, playback, interactions, submitted comment text, captions and hashtags.")
                    feature("lock.shield", "Where it stays", "Results stay on this iPhone until you choose to export JSON or CSV.")
                    feature("hand.draw", "Your control", "Review and delete individual posts before export, delete all results, or withdraw consent.")
                }
                .padding(20)
                .background(.white, in: RoundedRectangle(cornerRadius: 22))

                Toggle(isOn: $understands) {
                    Text("I agree to record posts I see, time visible, playback, taps and swipes, attempted comments and their text, captions and hashtags. Exports derive a suspected food topic from available post text and author handles.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                }
                .tint(Theme.accent)
                .padding(16)
                .background(Theme.paleAccent, in: RoundedRectangle(cornerRadius: 16))

                Button(action: onContinue) {
                    HStack {
                        Text("Agree & open Instagram")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline).padding(18).frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(understands ? Theme.ink : Theme.muted, in: RoundedRectangle(cornerRadius: 16))
                .disabled(!understands)

                Button("Preview example results", action: onPreview)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)

                Text("Independent prototype. Not affiliated with Instagram or Meta. Sign in only on Instagram’s own website in the browser below. It may restrict embedded browsers or change its layout.")
                    .font(.caption).foregroundStyle(Theme.muted)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(Theme.accent).frame(width: 27)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold()).foregroundStyle(Theme.ink)
                Text(detail).font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct BrowserFlow: View {
    @ObservedObject var store: DonationStore
    @Binding var hasConsented: Bool
    @State private var browser: InstagramWebSession?

    var body: some View {
        Group {
            if let browser {
                BrowserScreen(store: store, browser: browser, hasConsented: $hasConsented)
            } else {
                VStack(spacing: 15) {
                    ProgressView()
                    Text("Opening Instagram browser…")
                        .foregroundStyle(Theme.ink)
                    Button("Try again") { openBrowser() }
                        .font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            }
        }
        .onAppear {
            if browser == nil { openBrowser() }
        }
        .onDisappear { store.flush() }
    }

    private func openBrowser() {
        guard browser == nil else { return }
        let instance = InstagramWebSession()
        instance.store = store
        browser = instance
        instance.start()
    }
}

private struct BrowserScreen: View {
    @ObservedObject var store: DonationStore
    @ObservedObject var browser: InstagramWebSession
    @Binding var hasConsented: Bool
    @State private var menuOpen = false
    @State private var showingResults = false
    @State private var showingControl = false

    var body: some View {
        InstagramWebView(session: browser)
            .background(.white)
            .ignoresSafeArea(.container, edges: .bottom)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 9) {
                    if menuOpen {
                        VStack(alignment: .leading, spacing: 13) {
                            Text(store.isRecording
                                 ? (browser.pageRecording ? "RECORDING" : "STARTING RECORDER")
                                 : "PAUSED")
                                .font(.caption.bold()).foregroundStyle(Theme.accent)
                            Text("\(store.posts.count) posts saved")
                                .font(.headline).foregroundStyle(Theme.ink)
                            Text(browser.status)
                                .font(.caption).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            if let error = browser.recorderError {
                                Text(error)
                                    .font(.caption).foregroundStyle(.red)
                            } else if store.isRecording && browser.recorderReady && !browser.pageRecording {
                                Text(browser.pageObscured
                                     ? "Recording paused while an app screen is open"
                                     : "Recorder starting… Tap Reload if this persists.")
                                    .font(.caption).foregroundStyle(Theme.accent)
                            }
                            HStack(spacing: 14) {
                                Label("\(browser.candidateCount) found", systemImage: "square.stack")
                                Label("\(browser.visibleCount) visible", systemImage: "eye")
                            }
                            .font(.caption).foregroundStyle(Theme.muted)
                            Divider()
                            Button("See results") {
                                browser.setPageObscured(true)
                                store.flush()
                                showingResults = true; menuOpen = false
                            }
                            Button("Privacy & controls") {
                                browser.setPageObscured(true)
                                store.flush()
                                showingControl = true; menuOpen = false
                            }
                            HStack(spacing: 18) {
                                Button("Back") { browser.goBack() }
                                    .disabled(!browser.canGoBack)
                                Button("Reload") { browser.reload() }
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ink)
                        .padding(17)
                        .frame(width: 235, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19))
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    }
                    Button { menuOpen.toggle() } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(store.isRecording && browser.pageRecording
                                      ? Theme.accent : Theme.muted)
                                .frame(width: 8, height: 8)
                            Text("\(store.posts.count)")
                                .font(.caption.bold()).foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
                    }
                    .accessibilityLabel("Instagram Capture controls, \(store.posts.count) posts")
                }
                .padding(.leading, 8)
                .padding(.bottom, 86)
            }
            .sheet(isPresented: $showingResults, onDismiss: { updateObscured() }) {
                ResultsScreen(store: store) { showingResults = false }
            }
            .sheet(isPresented: $showingControl, onDismiss: { updateObscured() }) {
                PrivacyScreen(store: store, browser: browser, hasConsented: $hasConsented) {
                    showingControl = false
                }
            }
            .onAppear { updateObscured() }
            .onChange(of: showingResults) { showing in
                if showing { browser.setPageObscured(true) }
                else { scheduleResume() }
            }
            .onChange(of: showingControl) { showing in
                if showing { browser.setPageObscured(true) }
                else { scheduleResume() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                updateObscured()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                browser.setPageObscured(true)
                store.flush()
            }
    }

    private func updateObscured() {
        // The app uses a UIKit scene delegate, so rely on UIKit lifecycle
        // notifications and sheet state instead of a SwiftUI scenePhase value.
        browser.setPageObscured(showingResults || showingControl)
    }

    private func scheduleResume() {
        // The underlying web view may become visible after the sheet's dismissal callback.
        for delay in [0.15, 0.75, 1.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !showingResults, !showingControl,
                      UIApplication.shared.applicationState == .active else { return }
                browser.setPageObscured(false)
            }
        }
    }
}

private struct ResultsScreen: View {
    @ObservedObject var store: DonationStore
    let onClose: () -> Void
    @State private var showingSample = false
    @State private var showingDelete = false
    @State private var showingExportSettings = false
    @State private var showingLinkEntry = false
    @State private var linkTarget: UUID?
    @State private var linkInput = ""
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 12) {
                    Text("A window into what you saw.")
                        .font(.title2.bold()).foregroundStyle(Theme.ink)
                    Text("These records stay on this iPhone. Visible time is an estimate of time on screen, not a measure of attention.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)

                if !showingSample && !store.posts.isEmpty {
                    Text("Review the saved posts below before exporting. This list is not automatically anonymised: captions, comments, links and viewing patterns may identify you or others. Swipe left on a post to delete it before creating a file. Deleted posts will be absent from future exports; this cannot recall a file already shared.")
                        .font(.subheadline).foregroundStyle(Theme.ink)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.paleAccent, in: RoundedRectangle(cornerRadius: 16))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }

                if let error = store.storageError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }

                if showingSample {
                    sampleNotice.listRowBackground(Color.clear).listRowSeparator(.hidden)
                    ResultsContent(posts: DonationPost.examples)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Button("Back to my results") { showingSample = false }
                        .font(.subheadline.bold()).foregroundStyle(Theme.accent)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if store.posts.isEmpty {
                    emptyState.listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    Button { showingExportSettings = true } label: {
                        Label("Export my results", systemImage: "square.and.arrow.up")
                            .font(.headline).frame(maxWidth: .infinity).padding(17)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)

                    ResultsSummary(posts: store.posts)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)

                    Text("\(store.posts.filter { !$0.permalink.isEmpty }.count) of \(store.posts.count) posts have links. You can add a missing link to a specific post below.")
                        .font(.caption).foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)

                    Section("Recorded posts") {
                        ForEach(store.posts) { post in
                            ResultPostCard(post: post, isSample: false, onAddLink: {
                                linkTarget = post.id
                                linkInput = ""
                                showingLinkEntry = true
                            })
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { store.deletePost(post.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Button("Delete all saved results", role: .destructive) { showingDelete = true }
                        .font(.subheadline).frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Your results")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: onClose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.posts.isEmpty && !showingSample {
                        Button("See sample") { showingSample = true }
                            .font(.subheadline)
                    }
                }
            }
            .confirmationDialog("Delete all collected posts from this iPhone?",
                                isPresented: $showingDelete, titleVisibility: .visible) {
                Button("Delete all results", role: .destructive) { store.deleteAll() }
            }
            .sheet(isPresented: $showingExportSettings) { ExportSettingsScreen(store: store) }
            .alert("Attach a post link", isPresented: $showingLinkEntry) {
                TextField("Instagram post or Reel link", text: $linkInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save link") {
                    guard let linkTarget else { return }
                    do { try store.attachLink(linkInput, to: linkTarget) }
                    catch { exportError = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("For this exact post, tap Send in Instagram, then Copy Link. Return here and paste it.")
            }
            .alert("Could not complete action", isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } }
            )) {
                Button("OK") { exportError = nil }
            } message: { Text(exportError ?? "Please try again.") }
        }
    }

    private var sampleNotice: some View {
        Label("EXAMPLE DATA — never included in your export", systemImage: "sparkles")
            .font(.caption.bold())
            .foregroundStyle(Theme.accent)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paleAccent, in: RoundedRectangle(cornerRadius: 14))
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 46)).foregroundStyle(Theme.accent)
            Text("Nothing recorded yet")
                .font(.title3.bold()).foregroundStyle(Theme.ink)
            Text("Sign in on Instagram’s web page, then scroll Home or Reels. Open the floating recording control to check how many cards were found.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
            Button("Preview example results") { showingSample = true }
                .font(.subheadline.bold()).foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct SampleResultsScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("EXAMPLE DATA — no Instagram login needed", systemImage: "sparkles")
                        .font(.caption.bold()).foregroundStyle(Theme.accent)
                    ResultsContent(posts: DonationPost.examples)
                    Text("This preview uses fictional accounts. Open the floating control in the browser to see your actual results.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Example results")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct ResultsContent: View {
    let posts: [DonationPost]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ResultsSummary(posts: posts)
            Text("Example feed").font(.headline).foregroundStyle(Theme.ink)
            ForEach(posts) { post in
                ResultPostCard(post: post, isSample: true, onAddLink: nil)
            }
        }
    }
}

private struct ResultsSummary: View {
    let posts: [DonationPost]

    var body: some View {
        HStack(spacing: 10) {
            countCard("\(posts.count)", "POSTS")
            countCard("\(Int(posts.reduce(0.0) { $0 + $1.visibleSeconds }))s", "VISIBLE")
            countCard("\(posts.filter { $0.isVideo }.count)", "VIDEOS")
        }
    }

    private func countCard(_ number: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number).font(.title2.bold()).foregroundStyle(Theme.ink)
            Text(label).font(.system(size: 9, weight: .bold))
                .tracking(0.4).foregroundStyle(Theme.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ResultPostCard: View {
    let post: DonationPost
    let isSample: Bool
    let onAddLink: (() -> Void)?
    @State private var expandedCaption = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2).foregroundStyle(Theme.muted)
                Text(post.account).font(.subheadline.bold()).foregroundStyle(Theme.ink)
                Spacer()
                Text(post.label.rawValue.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.4)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(post.label == .post ? Theme.background : Theme.paleAccent,
                                in: Capsule())
                    .foregroundStyle(post.label == .post ? Theme.muted : Theme.accent)
            }
            Text(isSample ? "Example of a saved post" :
                 post.permalink.isEmpty ? "Post link unavailable · observation saved" :
                 post.permalink)
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Theme.muted)
            if !isSample, post.permalink.isEmpty, let onAddLink {
                Button("Add link from Instagram", action: onAddLink)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            if !post.caption.isEmpty {
                Text("Caption: \(post.caption)")
                    .font(.caption).foregroundStyle(Theme.ink)
                    .lineLimit(expandedCaption ? nil : 6)
                if post.caption.count > 250 {
                    Button(expandedCaption ? "Show less" : "Show full caption") {
                        expandedCaption.toggle()
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            if !post.hashtags.isEmpty {
                Text("Hashtags: \(post.hashtags.joined(separator: " "))")
                    .font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Label("\(Int(post.visibleSeconds.rounded()))s visible", systemImage: "eye")
                if post.isVideo {
                    Label(post.watchedPercent.map { "\($0)% watched" } ?? "Watch % unavailable",
                          systemImage: "play.rectangle")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.ink)
            Text("\(post.surface.rawValue) · \(post.relationship.rawValue) account")
                .font(.caption).foregroundStyle(Theme.muted)
            Text("Liked: \(post.wasLiked ? "Yes" : "No") · Saved: \(post.wasSaved ? "Yes" : "No") · Commented: \(post.wasCommented ? "Yes" : "No") · Interacted: \(post.wasInteractedWith ? "Yes" : "No")")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
            Text("Comments opened: \(post.commentsOpened ? "Yes" : "No") · Like \(post.likeTaps) · Save \(post.saveTaps) · Comments attempted \(post.commentSubmissions) · Follow \(post.followTaps)")
                .font(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Media taps \(post.mediaClicks) · Swipes \(post.swipes) · Pauses \(post.pauses) · Plays \(post.plays)")
                .font(.caption).foregroundStyle(Theme.muted)
            if post.wasCommented {
                Text("Your comment \(post.comments.count > 1 ? "attempts" : "attempt")")
                    .font(.caption.bold()).foregroundStyle(Theme.ink)
                if post.comments.isEmpty {
                    Text("Comment text unavailable")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                ForEach(Array(post.comments.enumerated()), id: \.offset) { _, comment in
                    Text("“\(comment.text)”")
                        .font(.caption).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Label("First viewed \(Self.viewedFormatter.string(from: post.seenAt))",
                      systemImage: "clock")
                    .font(.caption).foregroundStyle(Theme.muted)
                Spacer()
                if !isSample, !post.permalink.isEmpty,
                   let url = URL(string: post.permalink) {
                    Link("Open post ↗", destination: url)
                        .font(.caption.bold()).foregroundStyle(Theme.accent)
                }
            }
            if post.lastSeenAt.timeIntervalSince(post.seenAt) >= 1 {
                Text("Last recorded \(Self.viewedFormatter.string(from: post.lastSeenAt))")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
    }

    private static let viewedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct PrivacyScreen: View {
    @ObservedObject var store: DonationStore
    @ObservedObject var browser: InstagramWebSession
    @Binding var hasConsented: Bool
    let onClose: () -> Void
    @State private var confirmingLogin = false
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Your feed, your decision.")
                        .font(.title2.bold()).foregroundStyle(Theme.ink)
                    Text("The app records visible posts on Home and Reels, estimated time on screen, observed video seconds, Like and Save taps, whether comments were opened, attempted comments and their text, captions and hashtags, follows, media taps, swipes, play and pause actions. Account status is shown when Instagram reveals it. Export also derives a keyword-based food topic flag from available text. It does not record passwords, private messages, or browser cookies in results.")
                        .font(.subheadline).foregroundStyle(Theme.muted)

                    VStack(alignment: .leading, spacing: 17) {
                        Label("Recording runs while Instagram is visible and consent is active",
                              systemImage: "record.circle")
                            .font(.headline).foregroundStyle(Theme.ink)
                        Divider()
                        NavigationLink {
                            DiagnosticsScreen(browser: browser)
                        } label: {
                            Label("App log", systemImage: "list.bullet.rectangle")
                        }
                        .foregroundStyle(Theme.ink)
                        Button("Clear Instagram browser login") { confirmingLogin = true }
                            .foregroundStyle(Theme.ink)
                        Button("Delete saved results") { confirmingDelete = true }
                            .foregroundStyle(.red)
                        Button("Withdraw consent") {
                            store.setRecording(false)
                            browser.setRecording(false)
                            browser.clearDiagnostics()
                            UserDefaults.standard.set(0, forKey: "captureConsentVersion")
                            hasConsented = false
                        }
                        .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))

                    Text("Clearing the browser login and deleting results are separate actions. Exports already saved outside this app must be deleted separately. This independent prototype is not affiliated with Instagram or Meta.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Control")
            .toolbar { Button("Done", action: onClose) }
            .confirmationDialog("Sign out of this app’s Instagram browser?",
                                isPresented: $confirmingLogin, titleVisibility: .visible) {
                Button("Clear browser login", role: .destructive) { browser.clearLogin() }
            }
            .confirmationDialog("Delete every saved post from this iPhone?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete saved results", role: .destructive) { store.deleteAll() }
            }
        }
    }
}

private struct DiagnosticsScreen: View {
    @ObservedObject var browser: InstagramWebSession
    @State private var exportURL: URL?
    @State private var showingShare = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("A technical log for troubleshooting missing links and recording interruptions. It contains timestamps, fixed technical messages and counts—not usernames, post links, captions, comments, cookies or passwords. Timestamps can still reveal when you used the app.")
                    .font(.subheadline)
                Text("Only the latest 250 entries from this app session are kept in memory. Repeated messages are limited. This log is separate from research exports and is only shared if you choose to share it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep session log", isOn: Binding(
                    get: { browser.diagnosticLogging },
                    set: { browser.setDiagnosticLogging($0) }))
                Text("\(browser.pendingLinkCount) pending identities · \(browser.metadataCount) cached post identities")
                    .font(.caption)
                Button("Share diagnostic log") {
                    do {
                        exportURL = try browser.exportDiagnostics()
                        showingShare = true
                    } catch { errorMessage = "The diagnostic file could not be created. Please try again." }
                }
                .disabled(browser.diagnosticEntries.isEmpty)
                Button("Clear log", role: .destructive) { browser.clearDiagnostics() }
                Text("Clearing also removes the app’s temporary diagnostic file. It cannot delete copies you already shared.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Latest events first") {
                if browser.diagnosticEntries.isEmpty { Text("No diagnostic events in this session.") }
                ForEach(Array(browser.diagnosticEntries.reversed())) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.event.rawValue)
                        if let count = entry.count { Text("Count: \(count)").font(.caption) }
                        Text(entry.at, format: .dateTime.year().month().day().hour().minute().second())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("App log")
        .sheet(isPresented: $showingShare) {
            if let exportURL { ShareSheet(fileURL: exportURL) }
        }
        .alert("Could not export log", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "Please try again.") }
    }
}

private struct ExportSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: DonationStore
    @State private var options = ExportOptions()
    @State private var showingShare = false
    @State private var showingReviewPrompt = false
    @State private var exportURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    Picker("Format", selection: $options.format) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Date range", selection: $options.range) {
                        ForEach(ExportRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    TextField("Study ID / batch label (optional)", text: $options.studyTag)
                        .textInputAutocapitalization(.never)
                        .onChange(of: options.studyTag) { value in
                            options.studyTag = String(value.prefix(80))
                        }
                }
                Section {
                    Text("\(store.posts.filter { !$0.permalink.isEmpty }.count) of \(store.posts.count) saved posts have links.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    Toggle("Submitted comment text", isOn: $options.includeCommentText)
                    Toggle("Captions and hashtags", isOn: $options.includeCaptions)
                    Toggle("Post links", isOn: $options.includePostLinks)
                    Toggle("Timestamped action log", isOn: $options.includeInteractionLog)
                    Toggle("Posts without links", isOn: $options.includeUnlinked)
                } header: { Text("Include") } footer: {
                    Text("The author handle and your Instagram login are not direct export fields. Links and comment text are on by default; turn them off if needed. Every export contains durationViewedSeconds, commentsOpened, and suspectedFoodRelated. The food flag is a keyword guess from available caption, hashtags, author handle and submitted comment text, even when those texts are excluded from the file. Links, captions, comments and timestamps may still identify people.")
                }
                Section {
                    Button {
                        showingReviewPrompt = true
                    } label: {
                        Label("Create \(options.format.rawValue) file & share", systemImage: "square.and.arrow.up")
                            .font(.headline).frame(maxWidth: .infinity)
                    }
                } header: { EmptyView() } footer: {
                    Text("Review every post before sharing. Files already saved to Files or sent to researchers cannot be recalled by deleting posts here. Actions and comments are observed attempts; Instagram may not accept them.")
                }
            }
            .navigationTitle("Export settings")
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Have you removed posts you do not want to share?",
                                isPresented: $showingReviewPrompt, titleVisibility: .visible) {
                Button("Go back and review posts") { dismiss() }
                Button("I reviewed my posts · Create file") { createExport() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Did you delete any post that could identify you or that makes you uncomfortable? Your login and cookies are not in the file, but links, captions, comments and viewing patterns can identify you or others. The file is not automatically anonymised.")
            }
            .sheet(isPresented: $showingShare) {
                if let exportURL { ShareSheet(fileURL: exportURL) }
            }
            .alert("Export failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK") { errorMessage = nil } }
                message: { Text(errorMessage ?? "Please try again.") }
        }
    }

    private func createExport() {
        do {
            exportURL = try store.makeExport(options: options)
            showingShare = true
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
