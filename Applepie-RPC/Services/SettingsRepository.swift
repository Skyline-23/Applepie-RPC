//
//  SettingsRepository.swift
//  Applepie-RPC
//

import Foundation
import SwiftData

struct AppSettingsSnapshot: Equatable {
    let updateInterval: TimeInterval
    let isPaused: Bool

    static let `default` = AppSettingsSnapshot(updateInterval: 3.0, isPaused: false)
}

@MainActor
protocol SettingsRepository: AnyObject {
    var current: AppSettingsSnapshot { get }
    func setPaused(_ isPaused: Bool)
    func setUpdateInterval(_ interval: TimeInterval)
    func makeSettingsStream() -> AsyncStream<AppSettingsSnapshot>
}

@MainActor
final class SwiftDataSettingsRepository: ObservableObject, SettingsRepository {
    @Published private(set) var current: AppSettingsSnapshot = .default

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let appSettings: AppSettings
    private var continuations: [UUID: AsyncStream<AppSettingsSnapshot>.Continuation] = [:]

    init(modelContainer: ModelContainer? = nil) {
        let resolvedContainer: ModelContainer
        if let modelContainer {
            resolvedContainer = modelContainer
        } else if let created = try? ModelContainer(for: AppSettings.self) {
            resolvedContainer = created
        } else if let inMemory = try? ModelContainer(
            for: AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        ) {
            resolvedContainer = inMemory
        } else {
            fatalError("Failed to initialize SwiftData container for AppSettings")
        }

        self.modelContainer = resolvedContainer
        self.modelContext = resolvedContainer.mainContext

        if let existing = try? modelContext.fetch(FetchDescriptor<AppSettings>()).first {
            self.appSettings = existing
        } else {
            let created = AppSettings()
            modelContext.insert(created)
            self.appSettings = created
            saveChanges()
        }

        self.current = AppSettingsSnapshot(
            updateInterval: appSettings.updateInterval,
            isPaused: appSettings.isPaused
        )
    }

    func setPaused(_ isPaused: Bool) {
        guard appSettings.isPaused != isPaused else { return }
        appSettings.isPaused = isPaused
        publishAndPersist()
    }

    func setUpdateInterval(_ interval: TimeInterval) {
        guard appSettings.updateInterval != interval else { return }
        appSettings.updateInterval = interval
        publishAndPersist()
    }

    func makeSettingsStream() -> AsyncStream<AppSettingsSnapshot> {
        let id = UUID()
        let initial = current

        return AsyncStream(
            AppSettingsSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            continuation.yield(initial)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func publishAndPersist() {
        let snapshot = AppSettingsSnapshot(
            updateInterval: appSettings.updateInterval,
            isPaused: appSettings.isPaused
        )
        current = snapshot
        saveChanges()

        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func saveChanges() {
        do {
            try modelContext.save()
        } catch {
            debugLog("Failed to save AppSettings:", error)
        }
    }
}
