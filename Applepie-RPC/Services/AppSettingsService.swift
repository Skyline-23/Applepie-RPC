//
//  AppSettingsService.swift
//  Applepie-RPC
//

import Foundation
import SwiftData
import Combine

@MainActor
final class AppSettingsService {
    private(set) var container: ModelContainer?
    private(set) var appSettings: AppSettings?
    private var lastObservedPausedState: Bool?

    var isPaused: Bool {
        appSettings?.isPaused == true
    }

    func loadOrCreate() -> Double {
        var interval: Double = 1.0

        do {
            container = try ModelContainer(for: AppSettings.self)
            let list = try container?.mainContext.fetch(FetchDescriptor<AppSettings>())
            if let setting = list?.first {
                appSettings = setting
            } else {
                let newSetting = AppSettings()
                container?.mainContext.insert(newSetting)
                appSettings = newSetting
            }

            if let setting = appSettings {
                interval = setting.updateInterval
                lastObservedPausedState = setting.isPaused
            }
        } catch {
            debugLog("Failed to fetch AppSettings:", error)
        }

        return interval
    }

    func observeChanges(
        _ onChange: @escaping @MainActor (_ updated: AppSettings, _ previousPaused: Bool) -> Void
    ) -> AnyCancellable {
        NotificationCenter.default
            .publisher(for: ModelContext.didSave)
            .sink { [weak self] _ in
                guard let self, let context = self.container?.mainContext else { return }
                if let updated = try? context.fetch(FetchDescriptor<AppSettings>()).first {
                    let previousPaused = self.lastObservedPausedState ?? false
                    self.appSettings = updated
                    self.lastObservedPausedState = updated.isPaused
                    onChange(updated, previousPaused)
                }
            }
    }
}
