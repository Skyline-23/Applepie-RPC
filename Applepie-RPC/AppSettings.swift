//
//  AppSettings.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/20/25.
//

import Foundation
import SwiftData

@Model
class AppSettings {
    var updateInterval: Double
    var isPaused: Bool

    init(updateInterval: Double = 1, isPaused: Bool = false) {
        self.updateInterval = updateInterval
        self.isPaused = isPaused
    }
}
