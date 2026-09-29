# Instagram Capture for iPhone

An independent research prototype that opens Instagram's mobile website inside an iPhone app and saves observations locally. It is not affiliated with Instagram or Meta.

## What changed in version 1.9

- The results list is compact. The app no longer captures or exports post media. Previously stored media files are removed after the update opens, while the text and interaction records remain.
- A post's **commentsOpened** field is a yes/no value. Earlier numeric comment-open records migrate to yes if at least one opening was observed. The detailed interaction log no longer contains repeat comment-open events.
- Submitted comment text is shown directly beneath the post in Results when captured. It describes an observed submission attempt; Instagram may reject it. Comment text is included in exports by default, with an opt-out in Export settings.
- Every JSON or CSV row has a separate numeric **durationViewedSeconds** field. It is the estimated time the post was visible, rounded to one decimal place. The old `visibleSeconds` export field is removed.
- Every export row has a binary **suspectedFoodRelated** field. It checks available caption, hashtags, post author handle and submitted comment text against a conservative English and German keyword list. The flag is calculated locally at export and is not shown in the Results list. `false` also covers posts without enough text, and the heuristic can make mistakes. It does not inspect the post's visual content.
- Post links are included by default. The recorder now checks unique post links and post URL attributes in each card, author links and author attributes, and selected feed metadata. It updates a saved result if the page reveals a link or handle later. When several candidate links could refer to different posts, it leaves the field empty instead of assigning the wrong one.

## Install the update

The ZIP is Xcode source code, not an iPhone installer. You need a Mac with Xcode, an Apple Account and your iPhone.

1. Download and unzip this version on your Mac. Open `InstagramDonationIOS/InstagramDonation.xcodeproj` from **this** copy.
2. In Xcode, select the **InstagramDonation** target and open **Signing & Capabilities**. Choose your Apple Account for **Team**, with **Automatically manage signing** enabled.
3. Keep **exactly the same Bundle Identifier** used for the existing app. Do not delete the installed app first: running the update over it preserves its saved text results.
4. Choose your connected iPhone near Xcode's Run button, then press **Run ▶**. If prompted, trust the Mac and enable Developer Mode on the iPhone. A free Personal Team may require periodic signing renewal.
5. Accept the updated consent screen. It explains the text-based food flag and the current recording fields. The earlier results remain available.

If Xcode seems to launch an older version, choose **Product → Clean Build Folder** and Run again. If the screen is blank, open **View → Debug Area → Activate Console** and inspect the first error.

## Browse and export

1. Sign in on Instagram's own page inside the app and browse Home or Reels. Tap the small recording count near the lower left, then **See results**.
2. Results show visible time, video watch percentage when available, the post author's handle when identified, caption and hashtags when available, interaction attempts, whether comments were opened, and attempted comment text. Swipe left on any unwanted result to delete it.
3. For a post without an automatic link, tap **Add link from Instagram** on that exact result. In Instagram, use Send → Copy Link and paste it here. The app will not guess a link when identification is ambiguous.
4. Tap **Export my results** at the top. Choose JSON or CSV, date range and optional study label. Links and submitted comment text are on by default; you can turn them off, as well as captions, action logs and unlinked posts. Confirm that you reviewed the posts, then use the iOS share sheet to save the file in Files or share it.

The direct post author handle is deliberately omitted from exported fields because it can sometimes be the participant's own handle. The food flag may still use the handle locally, even if no author text is exported. The app does not put browser cookies, passwords or the participant's login into result fields. Links, captions, comments and distinctive viewing patterns may still identify someone. A file already shared cannot be recalled by deleting a local post.

The changing Instagram website can hide post identity and actions from the embedded browser. Some posts may still have an unknown author or no trustworthy link. Earlier results without links cannot always be repaired automatically; use the manual link control for those records. Viewing duration estimates on-screen time, not attention. Comment and interaction fields reflect observed attempts, not server confirmation. The food flag is a heuristic for research review, not a validated classification.

## For a developer

- `InstagramDonation/FeedObserver.js`: visible cards, author/link discovery, interactions, attempted comment text and playback observations.
- `InstagramDonation/FeedMetadata.js`: selected identity and caption metadata from feed responses already delivered to the page; it does not send full responses or credentials to native code.
- `InstagramDonation/InstagramBrowser.swift`: verified script bridge and identity matching.
- `InstagramDonation/DonationStore.swift`: migration, local persistence, deletion, food heuristic and JSON/CSV exports.
- `InstagramDonation/Views.swift`: consent, browser controls, Results and export settings.
- `node tests/observer.test.cjs`: recorder startup, identity recovery, link ambiguity, detached comments, playback and recycled cards.

The JavaScript tests and package structure can be checked outside macOS. A signed Xcode build and a live signed-in Instagram test require a Mac and an account.
