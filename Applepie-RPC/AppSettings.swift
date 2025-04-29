//
//  AppSettings.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/20/25.
//

import SwiftData

@Model
final class AppSettings {
    var updateInterval: Double = 5
    var isPaused: Bool = false
    var credentials: [String: String] = [:]
    
    init(updateInterval: Double = 5, isPaused: Bool = false, credentials: [String: String] = [:]) {
        self.updateInterval = updateInterval
        self.isPaused = isPaused
        self.credentials = credentials
    }
}
