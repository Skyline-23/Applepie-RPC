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
    
    init(updateInterval: Double = 3, isPaused: Bool = false) {
        self.updateInterval = updateInterval
        self.isPaused = isPaused
    }
}
