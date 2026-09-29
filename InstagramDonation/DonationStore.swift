import Foundation
import Combine
import UIKit

// Deliberately conservative text heuristic. A false value means no keyword was
// found in available text, not that the visual post was definitely not food.
enum FoodTopicDetector {
    private static let terms: Set<String> = [
        "food", "foodie", "foodies", "foodblog", "foodblogger", "foodbloggers",
        "foodporn", "foodstagram", "instafood", "foodlover", "foodphotography",
        "meal", "meals", "recipe", "recipes", "cooking", "cook", "chef",
        "baking", "bake", "bakery", "restaurant", "cafe", "café", "brunch",
        "breakfast", "lunch", "dinner", "dessert", "desserts", "snack", "snacks",
        "pizza", "pasta", "burger", "sushi", "salad", "chocolate", "cake",
        "vegan", "vegetarian", "delicious", "yummy", "tasty", "nutrition",
        "essen", "lebensmittel", "gericht", "gerichte", "rezept", "rezepte",
        "kochen", "koch", "küche", "backen", "bäckerei", "frühstück",
        "mittagessen", "abendessen", "speisen", "restaurantbesuch", "essenszeit",
        "kochbuch", "fruehstueck",
        "kuchen", "torte", "nachtisch", "schokolade", "lecker", "veganes",
        "vegetarisch", "ernährung", "mahlzeit", "mahlzeiten"
    ]

    static func suspectsFood(_ post: DonationPost) -> Bool {
        let texts = [post.caption, post.account] + post.hashtags + post.comments.map(\.text)
        return texts.contains { text in
            let camelSeparated = text.replacingOccurrences(
                of: "([\\p{Ll}\\d])([\\p{Lu}])", with: "$1 $2", options: .regularExpression)
            return camelSeparated.lowercased().components(separatedBy: .alphanumerics.inverted)
                .contains(where: terms.contains)
        }
    }
}

struct RecordedComment: Codable {
    let text: String
    let attemptedAt: Date
}

struct RecordedInteraction: Codable {
    let action: String
    let at: Date
    let direction: String?
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case json = "JSON"
    case csv = "CSV"
    var id: String { rawValue }
}

enum ExportRange: String, CaseIterable, Identifiable {
    case all = "All dates"
    case lastSevenDays = "Last 7 days"
    var id: String { rawValue }
}

struct ExportOptions {
    var format: ExportFormat = .json
    var range: ExportRange = .all
    var includeCommentText = true
    var includeCaptions = false
    var includePostLinks = true
    var includeInteractionLog = true
    var includeUnlinked = true
    var studyTag = ""
}

enum PostLabel: String, Codable, Equatable {
    case post = "Post"
    case suggested = "Suggested"
    case sponsored = "Sponsored"
}

enum AccountRelationship: String, Codable {
    case followed = "Followed"
    case suggested = "Suggested"
    case notFollowed = "Not followed"
    case unknown = "Unknown"
}

enum FeedSurface: String, Codable {
    case home = "Home"
    case reels = "Reels"
    case post = "Post"
}

struct DonationPost: Codable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id, permalink, observationId, account, label, seenAt, lastSeenAt, visibleSeconds
        case videoDurationSeconds, watchedSecondBuckets, likeTaps, commentsOpened
        case commentSubmissions, followTaps, relationship, surface, isVideo
        case saveTaps, unsaveTaps, unlikeTaps, mediaClicks, swipes, pauses, plays
        case comments, interactions
        case caption, hashtags
    }
    private enum LegacyKeys: String, CodingKey { case commentOpens }

    let id: UUID
    var permalink: String
    let observationId: String
    var account: String
    var caption: String
    var hashtags: [String]
    var label: PostLabel
    let seenAt: Date
    var lastSeenAt: Date
    var visibleSeconds: Double
    var videoDurationSeconds: Double?
    var watchedSecondBuckets: [Int]
    var likeTaps: Int
    var commentsOpened: Bool
    var commentSubmissions: Int
    var followTaps: Int
    var relationship: AccountRelationship
    var surface: FeedSurface
    var isVideo: Bool
    var saveTaps: Int
    var unsaveTaps: Int
    var unlikeTaps: Int
    var mediaClicks: Int
    var swipes: Int
    var pauses: Int
    var plays: Int
    var comments: [RecordedComment]
    var interactions: [RecordedInteraction]

    var wasLiked: Bool { likeTaps > 0 }
    var wasSaved: Bool { saveTaps > 0 }
    var wasCommented: Bool { commentSubmissions > 0 }
    var wasInteractedWith: Bool { !interactions.isEmpty ||
        likeTaps + saveTaps + commentSubmissions + followTaps > 0 || commentsOpened }

    var watchedPercent: Int? {
        guard isVideo, let videoDurationSeconds, videoDurationSeconds > 0 else { return nil }
        return min(100, Int((Double(watchedSecondBuckets.count) / ceil(videoDurationSeconds) * 100).rounded()))
    }

    init(permalink: String, observationId: String? = nil,
         account: String, label: PostLabel, seenAt: Date = .now,
         relationship: AccountRelationship = .unknown, surface: FeedSurface = .home,
         isVideo: Bool = false) {
        let identifier = UUID()
        id = identifier
        self.permalink = permalink
        self.observationId = observationId ?? identifier.uuidString
        self.account = account
        caption = ""
        hashtags = []
        self.label = label
        self.seenAt = seenAt
        lastSeenAt = seenAt
        visibleSeconds = 0
        videoDurationSeconds = nil
        watchedSecondBuckets = []
        likeTaps = 0
        commentsOpened = false
        commentSubmissions = 0
        followTaps = 0
        self.relationship = relationship
        self.surface = surface
        self.isVideo = isVideo
        saveTaps = 0
        unsaveTaps = 0
        unlikeTaps = 0
        mediaClicks = 0
        swipes = 0
        pauses = 0
        plays = 0
        comments = []
        interactions = []
    }

    // Existing v1 records load with sensible defaults instead of disappearing after an update.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try values.decode(UUID.self, forKey: .id)
        id = decodedId
        permalink = try values.decode(String.self, forKey: .permalink)
        observationId = (try? values.decode(String.self, forKey: .observationId)) ?? decodedId.uuidString
        account = try values.decode(String.self, forKey: .account)
        caption = (try? values.decode(String.self, forKey: .caption)) ?? ""
        hashtags = (try? values.decode([String].self, forKey: .hashtags)) ?? []
        label = try values.decode(PostLabel.self, forKey: .label)
        seenAt = try values.decode(Date.self, forKey: .seenAt)
        lastSeenAt = (try? values.decode(Date.self, forKey: .lastSeenAt)) ?? seenAt
        visibleSeconds = (try? values.decode(Double.self, forKey: .visibleSeconds)) ?? 0
        videoDurationSeconds = try? values.decode(Double.self, forKey: .videoDurationSeconds)
        watchedSecondBuckets = (try? values.decode([Int].self, forKey: .watchedSecondBuckets)) ?? []
        likeTaps = (try? values.decode(Int.self, forKey: .likeTaps)) ?? 0
        let previousInteractions = (try? values.decode([RecordedInteraction].self,
                                                       forKey: .interactions)) ?? []
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let legacyOpened = ((try? legacy.decode(Int.self, forKey: .commentOpens)) ?? 0) > 0
        commentsOpened = (try? values.decode(Bool.self, forKey: .commentsOpened)) ??
            (legacyOpened || previousInteractions.contains(where: { $0.action == "comments_open" }))
        commentSubmissions = (try? values.decode(Int.self, forKey: .commentSubmissions)) ?? 0
        followTaps = (try? values.decode(Int.self, forKey: .followTaps)) ?? 0
        relationship = (try? values.decode(AccountRelationship.self, forKey: .relationship)) ?? .unknown
        surface = (try? values.decode(FeedSurface.self, forKey: .surface)) ?? .home
        isVideo = (try? values.decode(Bool.self, forKey: .isVideo)) ?? (permalink.contains("/reel/"))
        saveTaps = (try? values.decode(Int.self, forKey: .saveTaps)) ?? 0
        unsaveTaps = (try? values.decode(Int.self, forKey: .unsaveTaps)) ?? 0
        unlikeTaps = (try? values.decode(Int.self, forKey: .unlikeTaps)) ?? 0
        mediaClicks = (try? values.decode(Int.self, forKey: .mediaClicks)) ?? 0
        swipes = (try? values.decode(Int.self, forKey: .swipes)) ?? 0
        pauses = (try? values.decode(Int.self, forKey: .pauses)) ?? 0
        plays = (try? values.decode(Int.self, forKey: .plays)) ?? 0
        comments = (try? values.decode([RecordedComment].self, forKey: .comments)) ?? []
        interactions = previousInteractions.filter { $0.action != "comments_open" }
    }

    static let examples: [DonationPost] = {
        var first = DonationPost(permalink: "", account: "city_archive", label: .post,
                                 relationship: .followed)
        first.visibleSeconds = 14
        first.likeTaps = 1
        first.saveTaps = 1
        var second = DonationPost(permalink: "", account: "garden_notes", label: .suggested,
                                  relationship: .suggested, surface: .reels, isVideo: true)
        second.visibleSeconds = 24
        second.videoDurationSeconds = 30
        second.watchedSecondBuckets = Array(0..<18)
        second.commentsOpened = true
        var third = DonationPost(permalink: "", account: "studio_example", label: .sponsored,
                                 relationship: .notFollowed)
        third.visibleSeconds = 7
        third.commentSubmissions = 1
        third.comments = [RecordedComment(text: "Example comment", attemptedAt: .now)]
        third.followTaps = 1
        return [first, second, third]
    }()
}

private enum ExportError: LocalizedError {
    case noPosts, noMatchingPosts
    var errorDescription: String? {
        switch self {
        case .noPosts: return "No recorded posts to export."
        case .noMatchingPosts: return "No posts match these export settings."
        }
    }
}

private enum PostLinkError: LocalizedError {
    case invalid, missing, alreadyAttached, duplicate

    var errorDescription: String? {
        switch self {
        case .invalid: return "Paste an Instagram post or Reel link copied from the selected post."
        case .missing: return "This saved observation could not be found."
        case .alreadyAttached: return "This observation already has a post link."
        case .duplicate: return "That link is already attached to another saved observation."
        }
    }
}

private enum TemporaryExportFiles {
    static func removeAll() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
        for url in files where
            (url.lastPathComponent.hasPrefix("instagram-capture-") ||
             url.lastPathComponent.hasPrefix("instagram-feed-donation-")) &&
            ["json", "csv"].contains(url.pathExtension.lowercased()) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor
final class DonationStore: ObservableObject {
    @Published private(set) var posts: [DonationPost] = []
    @Published private(set) var isRecording = false
    @Published var storageError: String?

    private let fileURL: URL
    private var lastExportURL: URL?
    private var pendingSave: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "InstagramCapture.persistence", qos: .utility)
    private let maxPosts = 10_000
    private var deletedObservationIDs = Set<String>()
    private var deletedPermalinks = Set<String>()

    init() {
        let defaults = UserDefaults.standard
        isRecording = defaults.bool(forKey: "homeFeedConsent") &&
            defaults.integer(forKey: "captureConsentVersion") >= 4
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeFeedDonation", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("posts.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                posts = try decoder.decode([DonationPost].self, from: data)
            } catch {
                storageError = "Saved results could not be loaded: \(error.localizedDescription)"
            }
        }
        let oldImages = folder.appendingPathComponent("images", isDirectory: true)
        saveQueue.async { [weak self] in
            do {
                if FileManager.default.fileExists(atPath: oldImages.path) {
                    try FileManager.default.removeItem(at: oldImages)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.storageError = "Older media files could not be removed: \(error.localizedDescription)"
                }
            }
            do { try TemporaryExportFiles.removeAll() }
            catch {
                DispatchQueue.main.async { [weak self] in
                    self?.storageError = "Older temporary exports could not be removed: \(error.localizedDescription)"
                }
            }
        }
        // Rewrite legacy records without image fields on the persistence queue.
        if !posts.isEmpty { save() }
    }

    func setRecording(_ enabled: Bool) {
        if !enabled && isRecording { flush() }
        isRecording = enabled
    }

    func record(_ payload: [String: Any]) {
        guard isRecording else { return }
        let rawURL = payload["permalink"] as? String ?? ""
        var permalink = ""
        if !rawURL.isEmpty {
            guard let canonical = canonicalPermalink(rawURL, allowShareQuery: false) else { return }
            permalink = canonical
        }
        let observationId = (payload["observationId"] as? String)
            .flatMap { UUID(uuidString: $0)?.uuidString }
        guard !permalink.isEmpty || observationId != nil else { return }
        if observationId.map(deletedObservationIDs.contains) == true ||
            (!permalink.isEmpty && deletedPermalinks.contains(permalink)) { return }
        let event = payload["event"] as? String ?? "impression"
        guard ["impression", "visible", "watch", "interaction", "relationship"].contains(event) else { return }

        let index: Int
        if let observationId,
           let existing = posts.firstIndex(where: { $0.observationId == observationId }) {
            index = existing
        } else if !permalink.isEmpty,
                  let existing = posts.firstIndex(where: { $0.permalink == permalink }) {
            index = existing
        } else {
            guard posts.count < maxPosts else { return }
            let account = validatedAccount(payload["account"] as? String)
            let label = validatedLabel(payload["label"] as? String)
            let relationship = validatedRelationship(payload["relationship"] as? String)
            let surface: FeedSurface
            switch payload["surface"] as? String {
            case "Reels": surface = .reels
            case "Post": surface = .post
            default: surface = .home
            }
            posts.insert(DonationPost(permalink: permalink,
                                      observationId: observationId, account: account, label: label,
                                      relationship: relationship, surface: surface,
                                      isVideo: (payload["isVideo"] as? Bool ?? false) ||
                                        permalink.contains("/reel/")), at: 0)
            index = 0
        }

        var post = posts[index]
        if post.permalink.isEmpty && !permalink.isEmpty { post.permalink = permalink }
        if event != "relationship" { post.lastSeenAt = .now }
        let account = validatedAccount(payload["account"] as? String)
        if account != "Unknown account" { post.account = account }
        if let value = payload["caption"] as? String {
            let content = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { post.caption = String(content.prefix(5_000)) }
        }
        if let values = payload["hashtags"] as? [String] {
            let tags = values.prefix(100).filter {
                $0.range(of: "^#[\\p{L}\\p{N}_]{1,100}$", options: .regularExpression) != nil
            }
            if !tags.isEmpty { post.hashtags = Array(Set(tags)).sorted() }
        }
        let label = validatedLabel(payload["label"] as? String)
        if label != .post { post.label = label }
        let relationship = validatedRelationship(payload["relationship"] as? String)
        if relationship != .unknown { post.relationship = relationship }
        if payload["surface"] as? String == "Reels" { post.surface = .reels }
        if payload["surface"] as? String == "Post" { post.surface = .post }
        if payload["isVideo"] as? Bool == true { post.isVideo = true }
        if let metadataDuration = payload["videoDuration"] as? Double,
           metadataDuration > 0, metadataDuration <= 36_000 {
            post.videoDurationSeconds = metadataDuration
        }

        switch event {
        case "visible":
            if let seconds = payload["seconds"] as? Double, seconds > 0, seconds <= 5 {
                post.visibleSeconds += seconds
            }
        case "watch":
            if let duration = payload["duration"] as? Double,
               duration > 0, duration <= 36_000 {
                post.videoDurationSeconds = duration
            }
            post.isVideo = true
            if let seconds = payload["buckets"] as? [Int] {
                let limit = post.videoDurationSeconds.map { Int(ceil($0)) } ?? 36_000
                let new = seconds.filter { $0 >= 0 && $0 < limit }
                post.watchedSecondBuckets = Array(Set(post.watchedSecondBuckets).union(new)).sorted()
            }
        case "interaction":
            let action = payload["action"] as? String ?? ""
            switch action {
            case "like": post.likeTaps += 1
            case "unlike": post.unlikeTaps += 1
            case "save": post.saveTaps += 1
            case "unsave": post.unsaveTaps += 1
            case "comments_open": post.commentsOpened = true
            case "comment_submit":
                post.commentSubmissions += 1
                if let value = payload["commentText"] as? String {
                    let content = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10_000))
                    if !content.isEmpty {
                        post.comments.append(RecordedComment(text: content, attemptedAt: .now))
                    }
                }
            case "follow": post.followTaps += 1
            case "media_click": post.mediaClicks += 1
            case "swipe": post.swipes += 1
            case "pause": post.pauses += 1
            case "play": post.plays += 1
            default: break
            }
            if ["like", "unlike", "save", "unsave", "comment_submit",
                "follow", "media_click", "swipe", "pause", "play"].contains(action) {
                let direction = ["left", "right", "up", "down"].contains(payload["direction"] as? String ?? "")
                    ? payload["direction"] as? String : nil
                post.interactions.append(RecordedInteraction(action: action, at: .now,
                                                             direction: direction))
            }
        default: break
        }
        posts[index] = post
        scheduleSave()
    }

    func attachLink(_ raw: String, to id: UUID) throws {
        guard let permalink = canonicalPermalink(
            raw.trimmingCharacters(in: .whitespacesAndNewlines), allowShareQuery: true
        ) else { throw PostLinkError.invalid }
        guard let index = posts.firstIndex(where: { $0.id == id }) else {
            throw PostLinkError.missing
        }
        guard posts[index].permalink.isEmpty else { throw PostLinkError.alreadyAttached }
        guard !posts.contains(where: { $0.permalink == permalink }) else {
            throw PostLinkError.duplicate
        }
        var post = posts[index]
        post.permalink = permalink
        posts[index] = post
        flush()
    }

    private func canonicalPermalink(_ raw: String, allowShareQuery: Bool) -> String? {
        guard let components = URLComponents(string: raw), components.scheme == "https",
              ["instagram.com", "www.instagram.com"].contains(
                components.host?.lowercased() ?? ""),
              components.user == nil, components.password == nil, components.port == nil,
              allowShareQuery || (components.query == nil && components.fragment == nil) else {
            return nil
        }
        let path = components.path.split(separator: "/").map(String.init)
        guard path.count == 2, ["p", "reel"].contains(path[0]),
              path[1].range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
        else { return nil }
        return "https://www.instagram.com/\(path[0])/\(path[1])/"
    }

    func flush(completion: (() -> Void)? = nil) {
        pendingSave?.cancel()
        pendingSave = nil
        save(completion: completion)
    }

    func deleteAll() {
        pendingSave?.cancel()
        pendingSave = nil
        posts.removeAll()
        save()
        do {
            try TemporaryExportFiles.removeAll()
        } catch {
            storageError = "Some temporary exports could not be removed: \(error.localizedDescription)"
        }
        lastExportURL = nil
    }

    func deletePost(_ id: UUID) {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        let post = posts.remove(at: index)
        deletedObservationIDs.insert(post.observationId)
        if !post.permalink.isEmpty { deletedPermalinks.insert(post.permalink) }
        flush()
        // Serialize cleanup before the next export, without blocking the swipe animation.
        saveQueue.async { [weak self] in
            do { try TemporaryExportFiles.removeAll() }
            catch {
                DispatchQueue.main.async { [weak self] in
                    self?.storageError = "Some temporary exports could not be removed: \(error.localizedDescription)"
                }
            }
        }
        lastExportURL = nil
    }

    func makeExport(options: ExportOptions = ExportOptions()) throws -> URL {
        guard !posts.isEmpty else { throw ExportError.noPosts }
        flush()
        // A prior deletion must finish purging old temporary files before a new file is made.
        saveQueue.sync {}
        let selected = posts.reversed().filter { post in
            (options.includeUnlinked || !post.permalink.isEmpty) &&
            (options.range == .all || post.seenAt >= Date().addingTimeInterval(-7 * 86_400))
        }
        guard !selected.isEmpty else { throw ExportError.noMatchingPosts }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let formatter = ISO8601DateFormatter()
        let notes = "durationViewedSeconds is estimated on-screen time, not attention. commentsOpened is a yes/no observation, not a comment count. suspectedFoodRelated is a keyword-based English/German guess from available caption, hashtags, post author handle and attempted comment text; false can also mean missing text. Taps and comment submissions are observed attempts. Some post links may be unavailable."
        var rows: [[String: Any]] = []
        for post in selected {
            let raw = try encoder.encode(post)
            guard var row = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
            else { continue }
            // The author of a post can be the participant. Do not export a handle field.
            row.removeValue(forKey: "account")
            row.removeValue(forKey: "visibleSeconds")
            row["durationViewedSeconds"] = (post.visibleSeconds * 10).rounded() / 10
            row["commentsOpened"] = post.commentsOpened
            row["suspectedFoodRelated"] = FoodTopicDetector.suspectsFood(post)
            if !options.includePostLinks { row.removeValue(forKey: "permalink") }
            if !options.includeCaptions {
                row.removeValue(forKey: "caption")
                row.removeValue(forKey: "hashtags")
            }
            row["wasLiked"] = post.wasLiked
            row["wasSaved"] = post.wasSaved
            row["wasCommented"] = post.wasCommented
            row["wasInteractedWith"] = post.wasInteractedWith
            if let watchedPercent = post.watchedPercent { row["watchedPercent"] = watchedPercent }
            if !options.includeCommentText {
                row["comments"] = post.comments.map { ["attemptedAt": formatter.string(from: $0.attemptedAt)] }
            }
            if !options.includeInteractionLog { row.removeValue(forKey: "interactions") }
            rows.append(row)
        }
        let data: Data
        if options.format == .json {
            let bundle: [String: Any] = [
                "formatVersion": 6, "exportedAt": formatter.string(from: .now),
                "studyTag": String(options.studyTag.prefix(80)), "notes": notes,
                "settings": ["range": options.range.rawValue,
                             "includeCommentText": options.includeCommentText,
                             "includeCaptions": options.includeCaptions,
                             "includePostLinks": options.includePostLinks,
                             "includeInteractionLog": options.includeInteractionLog,
                             "includeUnlinked": options.includeUnlinked],
                "posts": rows
            ]
            data = try JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
        } else {
            let columns = ["observationId", "id", "permalink", "caption", "hashtags", "label",
                "relationship", "surface", "seenAt", "lastSeenAt", "durationViewedSeconds",
                "isVideo", "videoDurationSeconds", "watchedSecondBuckets", "watchedPercent",
                "wasLiked", "likeTaps", "unlikeTaps", "wasSaved", "saveTaps", "unsaveTaps",
                "wasCommented", "commentSubmissions", "comments", "commentsOpened", "followTaps",
                "wasInteractedWith", "mediaClicks", "swipes", "pauses", "plays", "interactions",
                "suspectedFoodRelated", "studyTag"]
            let lines = [columns.joined(separator: ",")] + zip(rows, selected).map { row, post in
                columns.map { column -> String in
                    let value: String
                    if column == "studyTag" { value = String(options.studyTag.prefix(80)) }
                    else if column == "watchedPercent" { value = post.watchedPercent.map(String.init) ?? "" }
                    else if column == "commentsOpened" { value = post.commentsOpened ? "true" : "false" }
                    else if column == "suspectedFoodRelated" {
                        value = FoodTopicDetector.suspectsFood(post) ? "true" : "false"
                    }
                    else if let item = row[column] {
                        if let array = item as? [Any],
                           let json = try? JSONSerialization.data(withJSONObject: array, options: [.fragmentsAllowed]) {
                            value = String(data: json, encoding: .utf8) ?? ""
                        } else { value = String(describing: item) }
                    } else { value = "" }
                    // Prevent spreadsheet formula execution without changing the JSON original.
                    let safe = value.first.map { "=+-@".contains($0) } == true ? "'" + value : value
                    return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }.joined(separator: ",")
            }
            data = Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("instagram-capture-\(UUID().uuidString).\(options.format.rawValue.lowercased())")
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                               ofItemAtPath: url.path)
        lastExportURL = url
        return url
    }

    private func validatedAccount(_ raw: String?) -> String {
        guard let raw, raw.range(of: "^[A-Za-z0-9._]{1,30}$", options: .regularExpression) != nil else {
            return "Unknown account"
        }
        return raw
    }

    private func validatedLabel(_ raw: String?) -> PostLabel {
        if raw == "Sponsored" { return .sponsored }
        if raw == "Suggested" { return .suggested }
        return .post
    }

    private func validatedRelationship(_ raw: String?) -> AccountRelationship {
        switch raw {
        case "Followed": return .followed
        case "Suggested": return .suggested
        case "Not followed": return .notFollowed
        default: return .unknown
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save(completion: (() -> Void)? = nil) {
        let snapshot = posts
        let destination = fileURL
        saveQueue.async { [weak self] in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: destination, options: .atomic)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                                       ofItemAtPath: destination.path)
                DispatchQueue.main.async { [weak self] in
                    if self?.storageError?.hasPrefix("Results could not be saved") == true {
                        self?.storageError = nil
                    }
                    completion?()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.storageError = "Results could not be saved: \(error.localizedDescription)"
                    completion?()
                }
            }
        }
    }
}
