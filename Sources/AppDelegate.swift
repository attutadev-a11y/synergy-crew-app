import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = UIColor.voltageCharcoal
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = CrewViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

extension UIColor {
    /// VOLTAGE charcoal #0A0A0D — matches the crew dashboard background.
    static let voltageCharcoal = UIColor(red: 10.0 / 255.0, green: 10.0 / 255.0, blue: 13.0 / 255.0, alpha: 1.0)
}
