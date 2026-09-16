//
//  Build-time configuration, injected by the server's iOS builder.
//
import Foundation

enum Config {
    static let appName = "@@APP_NAME@@"
    static let server = "@@SERVER@@"
    static let token = "@@TOKEN@@"
    static let interval: Int = @@INTERVAL@@
}