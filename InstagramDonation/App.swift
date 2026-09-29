import SwiftUI
import UIKit

@main
final class FeedWindowAppDelegate: UIResponder, UIApplicationDelegate {}

final class FeedWindowSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var store: DonationStore?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let store = DonationStore()
        self.store = store
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: RootView(store: store))
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save capture history")
        store?.flush {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
        if store == nil, task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
}
