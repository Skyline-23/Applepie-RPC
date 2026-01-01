import Foundation
import SwiftUI

enum LocalizableKey {
    case localhostName
    case permissionRequired
    case permissionRequiredDesc
    case appName
    case connected
    case disconnected
    case updateInterval
    case llds(Int)
    case device
    case nowPlaying
    case noInformation
    case cacheClearedSuccessfully
    case cacheClearingFailed
    case clearCache
    case quit
    case q
    case pairingFailed
    case enterPairingPINNumber
    case enterThe4PINNumbersOnTheScreen
    case status
    case discord
    case checkForUpdates
}

extension LocalizableKey {
    var key: String {
        switch self {
        case .localhostName:
            return "LocalhostName"
        case .permissionRequired:
            return "Permission Required"
        case .permissionRequiredDesc:
            return "Permission Required Desc"
        case .appName:
            return "AppName"
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .updateInterval:
            return "Update Interval"
        case .llds:
            return "%llds"
        case .device:
            return "Device"
        case .nowPlaying:
            return "Now Playing"
        case .noInformation:
            return "No Information"
        case .cacheClearedSuccessfully:
            return "Cache cleared successfully"
        case .cacheClearingFailed:
            return "Cache clearing failed"
        case .clearCache:
            return "Clear Cache"
        case .quit:
            return "Quit"
        case .q:
            return "⌘Q"
        case .pairingFailed:
            return "Pairing Failed"
        case .enterPairingPINNumber:
            return "Enter pairing PIN Number"
        case .enterThe4PINNumbersOnTheScreen:
            return "Enter the 4 PIN numbers on the screen"
        case .status:
            return "Status"
        case .discord:
            return "Discord"
        case .checkForUpdates:
            return "Check for Updates"
        }
    }

    var localizedString: String {
        switch self {
        case .llds(let value):
            let format = NSLocalizedString(key, comment: "")
            return String.localizedStringWithFormat(format, value)
        default:
            return NSLocalizedString(key, comment: "")
        }
    }
}

extension String {
    static func localizable(_ key: LocalizableKey) -> String {
        key.localizedString
    }
}

extension LocalizedStringKey {
    static func localizable(_ key: LocalizableKey) -> LocalizedStringKey {
        switch key {
        case .llds(let value):
            let format = NSLocalizedString(key.key, comment: "")
            return LocalizedStringKey(String.localizedStringWithFormat(format, value))
        default:
            return LocalizedStringKey(key.key)
        }
    }
}

extension Text {
    init(localizable key: LocalizableKey) {
        self.init(LocalizedStringKey.localizable(key))
    }
}
