//
//  AppSettings.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/20/25.
//

import SwiftData

@Model
final class AppSettings {
    var updateInterval: Double = 3
    var isPaused: Bool = false
    var includesBetaUpdates: Bool = false
    
    init(
        updateInterval: Double = 3,
        isPaused: Bool = false,
        includesBetaUpdates: Bool = false
    ) {
        self.updateInterval = updateInterval
        self.isPaused = isPaused
        self.includesBetaUpdates = includesBetaUpdates
    }
}
