//
//  Legacy app-delegate style so the app builds with plain `swiftc` and no
//  storyboard/asset tooling beyond what the server supplies.
//
import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var agent: WymAgent?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let vc = ViewController()
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window

        agent = WymAgent { [weak vc] in
            vc?.setStatus("agent stopped")
        }
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.agent?.run()
        }
        return true
    }
}