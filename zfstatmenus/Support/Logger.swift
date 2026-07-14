import Foundation
import os

enum AppLog {
    static let general = Logger(subsystem: "com.zfstat.ZFStatMenus", category: "general")
    static let monitor = Logger(subsystem: "com.zfstat.ZFStatMenus", category: "monitor")
    static let token = Logger(subsystem: "com.zfstat.ZFStatMenus", category: "token")
    static let statusBar = Logger(subsystem: "com.zfstat.ZFStatMenus", category: "statusBar")
}
