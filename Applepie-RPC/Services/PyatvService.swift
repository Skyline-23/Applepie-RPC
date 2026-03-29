//
//  PyatvService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/25/25.
//

import Foundation
import PylibKit_Mac

struct PlaybackTimelineSnapshot: Equatable {
    let trackID: String?
    let title: String
    let artist: String?
    let album: String?
    let position: Double
    let duration: Double
}

enum PlaybackTransitionHeuristics {
    static func hasSameMarker(
        _ lhs: PlaybackTimelineSnapshot,
        _ rhs: PlaybackTimelineSnapshot
    ) -> Bool {
        lhs.trackID == rhs.trackID &&
        lhs.title == rhs.title &&
        lhs.artist == rhs.artist &&
        lhs.album == rhs.album
    }

    static func shouldDiscardLikelyStaleRemoteSnapshot(
        previous: PlaybackTimelineSnapshot?,
        current: PlaybackTimelineSnapshot?
    ) -> Bool {
        guard let previous, let current else { return false }
        guard hasSameMarker(previous, current) else { return false }

        // HomePod sometimes keeps the previous track marker around for one poll
        // after a remote skip, but the timeline snaps back near the start.
        let rewoundNearStart =
            previous.position >= 8 &&
            current.position <= 3 &&
            (previous.position - current.position) >= 5

        let durationChanged =
            previous.duration > 0 &&
            current.duration > 0 &&
            abs(previous.duration - current.duration) >= 2

        return rewoundNearStart || durationChanged
    }
}

enum PushPollingBridge {
    static func resultForPolling(
        latestResult: PyatvService.ATVFetchResult?,
        receivedAt: Date?,
        hasActiveConnection: Bool,
        ttl: TimeInterval,
        now: Date = Date()
    ) -> PyatvService.ATVFetchResult? {
        guard let latestResult, let receivedAt else { return nil }
        guard latestResult.connection == .connected else { return nil }

        if now.timeIntervalSince(receivedAt) <= ttl {
            return latestResult
        }

        guard hasActiveConnection else { return nil }
        return latestResult
    }
}

/// Service to fetch Apple TV now-playing info using PylibKit's pyatv bindings.
actor PyatvService {
    struct ATVProps {
        let trackID: String?
        let title: String
        let artist: String?
        let album: String?
        let position: Double
        let duration: Double
    }

    struct ATVFetchResult {
        let connection: ConnectionState
        let data: ATVProps?
    }

    private struct PairingSession {
        let handler: Pyatv.Interface.PairinghandlerInstance
        let config: Pyatv.Interface.BaseconfigInstance
        let proto: Pyatv.Const.PyatvProtocol_
    }

    private struct CachedConfig {
        let config: Pyatv.Interface.BaseconfigInstance
        let fetchedAt: Date
    }

    private struct CachedConnection {
        let atv: Pyatv.Interface.AppletvInstance
        var lastUsed: Date
    }

    private struct TrackMarker: Equatable {
        let trackID: String?
        let title: String
        let artist: String?
        let album: String?
    }

    private struct TimedPushResult {
        let result: ATVFetchResult
        let receivedAt: Date
    }

    private struct PersistedCredentialStore: Codable {
        var version: Int = 1
        var credentialsByKey: [String: [String: String]] = [:]
    }

    private struct PushSession {
        var continuations: [UUID: AsyncStream<ATVFetchResult>.Continuation] = [:]
        var supervisorTask: Task<Void, Never>?
        var generation: UInt64 = 0
        var atv: Pyatv.Interface.AppletvInstance?
        var updater: Pyatv.Interface.PushupdaterInstance?
        var listener: Pyatv.Interface.PushlistenerInstance?
        var deviceListener: Pyatv.Interface.DevicelistenerInstance?
        var proto: Pyatv.Const.PyatvProtocol_?
        var latestResult: TimedPushResult?
    }

    private enum PushUpdatePayload {
        case active(ATVProps)
        case inactive
        case ignore
    }

    private let executor: PythonExecutor
    private let pyatv: Pyatv.PyatvService
    private let loop: AsyncioLoop
    private let storage: Pyatv.Interface.StorageInstance?
    private let legacyStorageURL: URL
    private let credentialsURL: URL
    private let shield: Pyatv.Support.Shield.ShieldService
    private var persistedCredentialStore: PersistedCredentialStore
    private var pairings: [String: PairingSession] = [:]
    private var configCache: [String: CachedConfig] = [:]
    private var connectionCache: [String: CachedConnection] = [:]
    private var lastSuccessfulProtocol: [String: Pyatv.Const.PyatvProtocol_] = [:]
    private var lastEmittedTrackByHost: [String: TrackMarker] = [:]
    private var lastPlaybackSnapshotByHost: [String: PlaybackTimelineSnapshot] = [:]
    private var nilStateStagnationCountByHost: [String: Int] = [:]
    private var pushSessions: [String: PushSession] = [:]
    private let configTTL: TimeInterval = 300
    private let connectionTTL: TimeInterval = 120
    private let pushReconnectDelay: TimeInterval = 2
    private let pushResultTTL: TimeInterval = 2

    /// Factory to create and set up PyatvService.
    static func create(executor: PythonExecutor) async -> PyatvService {
        let pyatv = await Pyatv.PyatvService.create(executor: executor)
        let loop = await executor.createAsyncioLoop()
        let shield = await Pyatv.Support.Shield.ShieldService.create(executor: executor)

        var storage: Pyatv.Interface.StorageInstance? = nil
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let appDir = (baseDir ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Applepie-RPC", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let legacyStorageURL = appDir.appendingPathComponent("pyatv_storage.json")
        let credentialsURL = appDir.appendingPathComponent("pyatv_credentials.json")
        let persistedCredentialStore = Self.loadPersistedCredentialStore(
            from: credentialsURL,
            legacyStorageURL: legacyStorageURL
        )
        do {
            let memoryStorage = try await Pyatv.Storage.MemoryStorage.MemorystorageInstance.create(
                executor: executor
            )
            if let ref = await memoryStorage.objectRef() {
                storage = await Pyatv.Interface.StorageInstance.attach(executor: executor, ref: ref)
            }
        } catch {
            debugLog("[PyatvService] Failed to initialize storage: \(error)")
        }

        return PyatvService(
            executor: executor,
            pyatv: pyatv,
            loop: loop,
            storage: storage,
            legacyStorageURL: legacyStorageURL,
            credentialsURL: credentialsURL,
            shield: shield,
            persistedCredentialStore: persistedCredentialStore
        )
    }

    private init(
        executor: PythonExecutor,
        pyatv: Pyatv.PyatvService,
        loop: AsyncioLoop,
        storage: Pyatv.Interface.StorageInstance?,
        legacyStorageURL: URL,
        credentialsURL: URL,
        shield: Pyatv.Support.Shield.ShieldService,
        persistedCredentialStore: PersistedCredentialStore
    ) {
        self.executor = executor
        self.pyatv = pyatv
        self.loop = loop
        self.storage = storage
        self.legacyStorageURL = legacyStorageURL
        self.credentialsURL = credentialsURL
        self.shield = shield
        self.persistedCredentialStore = persistedCredentialStore
    }

    private static func normalizeStoreKey(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func protocolKey(_ proto: Pyatv.Const.PyatvProtocol_) -> String {
        proto.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func protocolKey(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadPersistedCredentialStore(
        from credentialsURL: URL,
        legacyStorageURL: URL
    ) -> PersistedCredentialStore {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: credentialsURL),
           let decoded = try? decoder.decode(PersistedCredentialStore.self, from: data) {
            return decoded
        }

        let migrated = migrateLegacyCredentialStore(from: legacyStorageURL)
        if !migrated.credentialsByKey.isEmpty {
            savePersistedCredentialStore(migrated, to: credentialsURL)
        }
        return migrated
    }

    private static func migrateLegacyCredentialStore(from legacyStorageURL: URL) -> PersistedCredentialStore {
        guard let data = try? Data(contentsOf: legacyStorageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [[String: Any]] else {
            return PersistedCredentialStore()
        }

        var migrated = PersistedCredentialStore()
        for device in devices {
            guard let protocols = device["protocols"] as? [String: Any] else { continue }
            for (rawProtocol, rawEntry) in protocols {
                guard let entry = rawEntry as? [String: Any],
                      let credentials = entry["credentials"] as? String,
                      !credentials.isEmpty else {
                    continue
                }
                guard let key = normalizeStoreKey(entry["identifier"] as? String) else {
                    continue
                }
                migrated.credentialsByKey[key, default: [:]][protocolKey(rawProtocol)] = credentials
            }
        }
        return migrated
    }

    private static func savePersistedCredentialStore(_ store: PersistedCredentialStore, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            debugLog("[PyatvService] Failed to save credential store: \(error)")
        }
    }

    private func ensureStorageLoaded() async {
        guard let storage else { return }
        do {
            try await storage.load()
        } catch {
            debugLog("[PyatvService] Storage load failed: \(error)")
        }
    }

    private func credentialLookupKeys(
        for config: Pyatv.Interface.BaseconfigInstance,
        host: String
    ) async -> [String] {
        var keys: [String] = []

        if let identifier = try? await config.identifier(),
           let normalized = Self.normalizeStoreKey(identifier) {
            keys.append(normalized)
        }

        if let services = try? await config.services() {
            for service in services {
                if let identifier = try? await service.identifier(),
                   let normalized = Self.normalizeStoreKey(identifier) {
                    keys.append(normalized)
                }
            }
        }

        if let normalizedHost = Self.normalizeStoreKey(host) {
            keys.append(normalizedHost)
        }

        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private func persistedCredentials(
        for config: Pyatv.Interface.BaseconfigInstance,
        host: String,
        proto: Pyatv.Const.PyatvProtocol_
    ) async -> String? {
        let keys = await credentialLookupKeys(for: config, host: host)
        let protoKey = Self.protocolKey(proto)

        for key in keys {
            if let credentials = persistedCredentialStore.credentialsByKey[key]?[protoKey],
               !credentials.isEmpty {
                return credentials
            }
        }

        return nil
    }

    private func applyPersistedCredentials(
        to config: Pyatv.Interface.BaseconfigInstance,
        host: String
    ) async {
        guard let services = try? await config.services() else { return }

        for service in services {
            guard let proto = try? await service.protocol() else { continue }
            guard let credentials = await persistedCredentials(for: config, host: host, proto: proto) else {
                continue
            }
            let applied = (try? await config.set_credentials(protocol_: proto, credentials: credentials)) ?? false
            if applied {
                debugLog("[PyatvService] restored persisted credentials (host=\(host), proto=\(proto))")
            }
        }
    }

    private func persistCredentials(
        _ credentials: String,
        for config: Pyatv.Interface.BaseconfigInstance,
        host: String,
        proto: Pyatv.Const.PyatvProtocol_
    ) async {
        let keys = await credentialLookupKeys(for: config, host: host)
        guard !keys.isEmpty else { return }

        let protoKey = Self.protocolKey(proto)
        for key in keys {
            persistedCredentialStore.credentialsByKey[key, default: [:]][protoKey] = credentials
        }
        Self.savePersistedCredentialStore(persistedCredentialStore, to: credentialsURL)
    }

    private func clearPersistedCredentials() {
        persistedCredentialStore = PersistedCredentialStore()
        Self.savePersistedCredentialStore(persistedCredentialStore, to: credentialsURL)

        if FileManager.default.fileExists(atPath: legacyStorageURL.path) {
            try? FileManager.default.removeItem(at: legacyStorageURL)
        }
    }

    private struct TimeoutError: Error {
        let operation: String
        let seconds: Double
    }

    private func withTimeout<T>(
        seconds: Double,
        operation: String,
        _ work: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await work()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError(operation: operation, seconds: seconds)
            }
            guard let result = try await group.next() else {
                throw TimeoutError(operation: operation, seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }

    private func cachedConfig(for host: String) -> Pyatv.Interface.BaseconfigInstance? {
        if let cached = configCache[host] {
            if Date().timeIntervalSince(cached.fetchedAt) <= configTTL {
                return cached.config
            }
            configCache.removeValue(forKey: host)
        }
        return nil
    }

    private func storeConfig(_ config: Pyatv.Interface.BaseconfigInstance, host: String) {
        configCache[host] = CachedConfig(config: config, fetchedAt: Date())
    }

    private func connectionKey(host: String, proto: Pyatv.Const.PyatvProtocol_) -> String {
        return "\(host)|\(proto.rawValue)"
    }

    private func cachedConnection(host: String, proto: Pyatv.Const.PyatvProtocol_) async -> Pyatv.Interface.AppletvInstance? {
        let key = connectionKey(host: host, proto: proto)
        if var cached = connectionCache[key] {
            if Date().timeIntervalSince(cached.lastUsed) <= connectionTTL {
                if await isBlocking(cached.atv, host: host, proto: proto, context: "cache") {
                    await closeConnection(forKey: key)
                    return nil
                }
                cached.lastUsed = Date()
                connectionCache[key] = cached
                return cached.atv
            }
            await closeConnection(forKey: key)
        }
        return nil
    }

    private func isBlocking(
        _ atv: Pyatv.Interface.AppletvInstance,
        host: String,
        proto: Pyatv.Const.PyatvProtocol_,
        context: String
    ) async -> Bool {
        do {
            if let blocking = try await shield.is_blocking(obj: atv), blocking {
                debugLog("[PyatvService] connection blocked (host=\(host), proto=\(proto), context=\(context))")
                return true
            }
        } catch {
            debugLog("[PyatvService] shield check failed (host=\(host), proto=\(proto), context=\(context)): \(error)")
        }
        return false
    }

    private func storeConnection(_ atv: Pyatv.Interface.AppletvInstance, host: String, proto: Pyatv.Const.PyatvProtocol_) {
        let key = connectionKey(host: host, proto: proto)
        connectionCache[key] = CachedConnection(atv: atv, lastUsed: Date())
    }

    private func closeConnection(forKey key: String) async {
        if let cached = connectionCache.removeValue(forKey: key) {
            _ = try? await cached.atv.close()
        }
    }

    private func availableProtocols(
        for config: Pyatv.Interface.BaseconfigInstance
    ) async -> [Pyatv.Const.PyatvProtocol_] {
        guard let services = try? await config.services(), !services.isEmpty else { return [] }
        var collected: [Pyatv.Const.PyatvProtocol_] = []
        for service in services {
            if let proto = try? await service.protocol() {
                collected.append(proto)
            }
        }
        if !collected.isEmpty {
            let protos = collected.map { String(describing: $0) }
            debugLog("[PyatvService] Available protocols:", protos.joined(separator: ", "))
        }
        return collected
    }

    private func deduplicatedProtocolOrder(
        _ candidates: [Pyatv.Const.PyatvProtocol_],
        available: [Pyatv.Const.PyatvProtocol_]
    ) -> [Pyatv.Const.PyatvProtocol_] {
        var seen = Set<String>()
        let ordered = candidates.filter { proto in
            let key = proto.rawValue
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        let filtered = ordered.filter { available.contains($0) }
        return filtered.isEmpty ? ordered : filtered
    }

    private func fetchProtocolOrder(
        host: String,
        available: [Pyatv.Const.PyatvProtocol_]
    ) -> [Pyatv.Const.PyatvProtocol_] {
        var desiredOrder: [Pyatv.Const.PyatvProtocol_] = []
        if let lastProto = lastSuccessfulProtocol[host] {
            desiredOrder.append(lastProto)
        }
        desiredOrder.append(contentsOf: [.mRP, .companion, .airPlay])
        return deduplicatedProtocolOrder(desiredOrder, available: available)
    }

    private func pushProtocolOrder(
        host: String,
        available: [Pyatv.Const.PyatvProtocol_]
    ) -> [Pyatv.Const.PyatvProtocol_] {
        var desiredOrder: [Pyatv.Const.PyatvProtocol_] = [.mRP]
        if let lastProto = lastSuccessfulProtocol[host] {
            desiredOrder.append(lastProto)
        }
        desiredOrder.append(contentsOf: [.companion, .airPlay])
        return deduplicatedProtocolOrder(desiredOrder, available: available)
    }

    private func normalizeMetadataField(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func makeTrackMarker(
        trackID: String?,
        title: String,
        artist: String?,
        album: String?
    ) -> TrackMarker? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        return TrackMarker(
            trackID: trackID,
            title: trimmedTitle,
            artist: normalizeMetadataField(artist),
            album: normalizeMetadataField(album)
        )
    }

    private func didTrackChange(host: String, marker: TrackMarker) -> Bool {
        guard let previous = lastEmittedTrackByHost[host] else { return true }
        return previous != marker
    }

    private func rememberTrack(host: String, marker: TrackMarker) {
        lastEmittedTrackByHost[host] = marker
    }

    private func resetNilStateStagnation(host: String) {
        nilStateStagnationCountByHost[host] = 0
    }

    private func shouldTreatNilStateAsInactive(
        host: String,
        marker: TrackMarker?,
        position: Double,
        duration: Double
    ) -> Bool {
        guard let marker else {
            resetNilStateStagnation(host: host)
            return false
        }
        guard
            let current = makePlaybackSnapshot(marker: marker, position: position, duration: duration),
            let previous = lastPlaybackSnapshotByHost[host]
        else {
            resetNilStateStagnation(host: host)
            return false
        }
        guard PlaybackTransitionHeuristics.hasSameMarker(previous, current) else {
            resetNilStateStagnation(host: host)
            return false
        }

        let hasTimelineSignal = duration > 0 || previous.duration > 0 || position > 0 || previous.position > 0
        guard hasTimelineSignal else {
            resetNilStateStagnation(host: host)
            return false
        }

        let delta = abs(position - previous.position)
        if delta < 0.2 {
            let count = (nilStateStagnationCountByHost[host] ?? 0) + 1
            nilStateStagnationCountByHost[host] = count
            return count >= 1
        }

        resetNilStateStagnation(host: host)
        return false
    }

    private func shouldDiscardLikelyStaleRemoteSnapshot(
        host: String,
        marker: TrackMarker?,
        position: Double,
        duration: Double
    ) -> Bool {
        PlaybackTransitionHeuristics.shouldDiscardLikelyStaleRemoteSnapshot(
            previous: lastPlaybackSnapshotByHost[host],
            current: makePlaybackSnapshot(marker: marker, position: position, duration: duration)
        )
    }

    private func makePlaybackSnapshot(
        marker: TrackMarker?,
        position: Double,
        duration: Double
    ) -> PlaybackTimelineSnapshot? {
        guard let marker else { return nil }
        return PlaybackTimelineSnapshot(
            trackID: marker.trackID,
            title: marker.title,
            artist: marker.artist,
            album: marker.album,
            position: position,
            duration: duration
        )
    }

    private func rememberPlaybackSnapshot(
        host: String,
        marker: TrackMarker?,
        position: Double,
        duration: Double
    ) {
        guard let snapshot = makePlaybackSnapshot(marker: marker, position: position, duration: duration) else {
            resetNilStateStagnation(host: host)
            return
        }
        lastPlaybackSnapshotByHost[host] = snapshot
        resetNilStateStagnation(host: host)
    }

    private func bridgedPushResultForPolling(host: String) -> ATVFetchResult? {
        guard let session = pushSessions[host] else { return nil }
        guard let latest = session.latestResult else { return nil }

        let bridged = PushPollingBridge.resultForPolling(
            latestResult: latest.result,
            receivedAt: latest.receivedAt,
            hasActiveConnection: hasActivePushConnection(host: host),
            ttl: pushResultTTL
        )

        guard let bridged else { return nil }

        if Date().timeIntervalSince(latest.receivedAt) > pushResultTTL {
            debugLog("[PyatvService] reusing active push snapshot to avoid polling reconnect (host=\(host))")
        }

        return bridged
    }

    private func hasPushSubscribers(host: String) -> Bool {
        !(pushSessions[host]?.continuations.isEmpty ?? true)
    }

    private func hasActivePushConnection(host: String) -> Bool {
        guard let session = pushSessions[host] else { return false }
        return session.atv != nil && session.updater != nil
    }

    private func nextPushGeneration(host: String) -> UInt64 {
        var session = pushSessions[host] ?? PushSession()
        session.generation &+= 1
        let generation = session.generation
        pushSessions[host] = session
        return generation
    }

    private func isCurrentPushGeneration(host: String, generation: UInt64) -> Bool {
        pushSessions[host]?.generation == generation
    }

    private func broadcastPushResult(host: String, result: ATVFetchResult) {
        guard var session = pushSessions[host] else { return }
        session.latestResult = TimedPushResult(result: result, receivedAt: Date())
        let continuations = Array(session.continuations.values)
        pushSessions[host] = session
        for continuation in continuations {
            continuation.yield(result)
        }
    }

    private func storePushConnection(
        host: String,
        generation: UInt64,
        proto: Pyatv.Const.PyatvProtocol_,
        atv: Pyatv.Interface.AppletvInstance,
        updater: Pyatv.Interface.PushupdaterInstance,
        listener: Pyatv.Interface.PushlistenerInstance,
        deviceListener: Pyatv.Interface.DevicelistenerInstance
    ) {
        guard var session = pushSessions[host], session.generation == generation else { return }
        session.proto = proto
        session.atv = atv
        session.updater = updater
        session.listener = listener
        session.deviceListener = deviceListener
        pushSessions[host] = session
    }

    private func clearPushConnection(host: String) async {
        guard var session = pushSessions[host] else { return }
        let updater = session.updater
        let atv = session.atv
        session.proto = nil
        session.updater = nil
        session.atv = nil
        session.listener = nil
        session.deviceListener = nil
        pushSessions[host] = session
        try? await updater?.stop()
        _ = try? await atv?.close()
    }

    private func stopPushSession(host: String) async {
        guard let session = pushSessions.removeValue(forKey: host) else { return }
        session.supervisorTask?.cancel()
        try? await session.updater?.stop()
        _ = try? await session.atv?.close()
    }

    private func finalizePushSupervisor(host: String) {
        guard var session = pushSessions[host] else { return }
        session.supervisorTask = nil
        if session.continuations.isEmpty {
            pushSessions.removeValue(forKey: host)
        } else {
            pushSessions[host] = session
        }
    }

    private func ensurePushSupervisor(host: String) {
        var session = pushSessions[host] ?? PushSession()
        guard session.supervisorTask == nil else {
            pushSessions[host] = session
            return
        }
        session.supervisorTask = Task { [host] in
            await self.runPushSupervisor(host: host)
        }
        pushSessions[host] = session
    }

    private func runPushSupervisor(host: String) async {
        defer { finalizePushSupervisor(host: host) }

        while hasPushSubscribers(host: host) && !Task.isCancelled {
            if hasActivePushConnection(host: host) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            await establishPushSession(host: host)

            if hasActivePushConnection(host: host) {
                continue
            }

            try? await Task.sleep(
                nanoseconds: UInt64(pushReconnectDelay * 1_000_000_000)
            )
        }

        if pushSessions[host] != nil {
            await clearPushConnection(host: host)
        }
    }

    private func addPushSubscriber(
        host: String,
        id: UUID,
        continuation: AsyncStream<ATVFetchResult>.Continuation
    ) {
        var session = pushSessions[host] ?? PushSession()
        session.continuations[id] = continuation
        let latest = session.latestResult
        pushSessions[host] = session
        if let latest {
            continuation.yield(latest.result)
        }
        ensurePushSupervisor(host: host)
    }

    private func removePushSubscriber(host: String, id: UUID) async {
        guard var session = pushSessions[host] else { return }
        session.continuations.removeValue(forKey: id)
        pushSessions[host] = session
        if session.continuations.isEmpty {
            await stopPushSession(host: host)
        }
    }

    private func establishPushSession(host: String) async {
        do {
            let config = try await withTimeout(seconds: 8, operation: "push_scan") {
                try await self.scanConfig(host: host)
            }
            guard let config else {
                debugLog("[PyatvService] push scan returned no config (host=\(host))")
                return
            }

            let available = await availableProtocols(for: config)
            for proto in pushProtocolOrder(host: host, available: available) {
                guard hasPushSubscribers(host: host), !Task.isCancelled else { return }

                do {
                    debugLog("[PyatvService] starting push updater (host=\(host), proto=\(proto))")
                    let connected = try await withTimeout(seconds: 8, operation: "push_connect") {
                        try await self.pyatv.connect(
                            config: config,
                            loop: self.loop,
                            protocol_: proto,
                            storage: self.storage
                        )
                    }
                    guard let atv = connected else {
                        debugLog("[PyatvService] push connect returned nil (host=\(host), proto=\(proto))")
                        continue
                    }

                    if await isBlocking(atv, host: host, proto: proto, context: "push_preflight") {
                        _ = try? await atv.close()
                        continue
                    }

                    guard let updater = try await withTimeout(seconds: 3, operation: "push_updater", {
                        try await atv.push_updater()
                    }) else {
                        debugLog("[PyatvService] push updater unavailable (host=\(host), proto=\(proto))")
                        _ = try? await atv.close()
                        continue
                    }

                    let generation = nextPushGeneration(host: host)
                    let listener = try await Pyatv.Interface.PushlistenerInstance.create(executor: executor)
                    let deviceListener = try await Pyatv.Interface.DevicelistenerInstance.create(executor: executor)

                    guard
                        let listenerRef = await listener.objectRef(),
                        let deviceListenerRef = await deviceListener.objectRef()
                    else {
                        _ = try? await updater.stop()
                        _ = try? await atv.close()
                        debugLog("[PyatvService] push listener ref unavailable (host=\(host), proto=\(proto))")
                        continue
                    }

                    let onUpdate = await executor.buildCallable(
                        names: ["updater", "playstatus"],
                        callableName: "push_playstatus_update"
                    ) { [host, generation, proto] (_: Any, playstatus: Pyatv.Interface.PlayingInstance) -> Bool in
                        Task {
                            await self.handlePushUpdate(
                                host: host,
                                generation: generation,
                                proto: proto,
                                playstatus: playstatus
                            )
                        }
                        return true
                    }
                    let onError = await executor.buildCallable(
                        names: ["updater", "exception"],
                        callableName: "push_playstatus_error"
                    ) { [host, generation, proto] (_: Any, exception: Any) -> Bool in
                        Task {
                            await self.handlePushError(
                                host: host,
                                generation: generation,
                                proto: proto,
                                exception: exception
                            )
                        }
                        return true
                    }
                    let onConnectionLost = await executor.buildCallable(
                        names: ["exception"],
                        callableName: "push_connection_lost"
                    ) { [host, generation, proto] (exception: Any) -> Bool in
                        Task {
                            await self.handlePushDisconnect(
                                host: host,
                                generation: generation,
                                proto: proto,
                                reason: "connection_lost",
                                details: String(describing: exception)
                            )
                        }
                        return true
                    }
                    let onConnectionClosed = await executor.buildCallable(
                        callableName: "push_connection_closed"
                    ) { [host, generation, proto] () -> Bool in
                        Task {
                            await self.handlePushDisconnect(
                                host: host,
                                generation: generation,
                                proto: proto,
                                reason: "connection_closed",
                                details: nil
                            )
                        }
                        return true
                    }

                    try await listenerRef.playstatus_update.setValue(onUpdate)
                    try await listenerRef.playstatus_error.setValue(onError)
                    try await deviceListenerRef.connection_lost.setValue(onConnectionLost)
                    try await deviceListenerRef.connection_closed.setValue(onConnectionClosed)
                    try await updater.set_listener(target: listenerRef)
                    try await atv.set_listener(target: deviceListenerRef)

                    storePushConnection(
                        host: host,
                        generation: generation,
                        proto: proto,
                        atv: atv,
                        updater: updater,
                        listener: listener,
                        deviceListener: deviceListener
                    )

                    try await withTimeout(seconds: 3, operation: "push_start") {
                        try await updater.start(initial_delay: 0)
                    }
                    debugLog("[PyatvService] push updater started (host=\(host), proto=\(proto))")
                    return
                } catch let timeout as TimeoutError {
                    debugLog("[PyatvService] \(timeout.operation) timed out after \(timeout.seconds)s (host=\(host), proto=\(proto))")
                    await clearPushConnection(host: host)
                } catch {
                    debugLog("[PyatvService] push setup failed (host=\(host), proto=\(proto)): \(error)")
                    await clearPushConnection(host: host)
                }
            }
        } catch let timeout as TimeoutError {
            debugLog("[PyatvService] \(timeout.operation) timed out after \(timeout.seconds)s (host=\(host))")
        } catch {
            debugLog("[PyatvService] push setup failed (host=\(host)): \(error)")
        }
    }

    private func decodePushUpdate(
        host: String,
        proto: Pyatv.Const.PyatvProtocol_,
        playing: Pyatv.Interface.PlayingInstance
    ) async -> PushUpdatePayload {
        func timed<T>(
            _ operation: String,
            seconds: Double = 2.0,
            _ work: @escaping () async throws -> T
        ) async throws -> T {
            try await self.withTimeout(seconds: seconds, operation: operation, work)
        }

        do {
            let title = (try await timed("push_title") { try await playing.title() }) ?? ""
            let artist = try await timed("push_artist") { try await playing.artist() }
            let album = try await timed("push_album") { try await playing.album() }
            let deviceState = try? await timed("push_device_state") {
                try await playing.device_state()
            }

            if let deviceState,
               deviceState != .playing && deviceState != .seeking {
                debugLog("[PyatvService] push reported inactive state=\(deviceState) (host=\(host), proto=\(proto))")
                return .inactive
            }

            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                return .inactive
            }

            let itunesId = try await timed("push_itunes_store_identifier") {
                try await playing.itunes_store_identifier()
            }
            let contentIdentifier = try await timed("push_content_identifier") {
                try await playing.content_identifier()
            }
            let playbackHash = try await timed("push_playback_hash") {
                try await playing.hash()
            }
            let trackID = itunesId.flatMap { $0 > 0 ? String($0) : nil }
                ?? normalizeMetadataField(contentIdentifier)
                ?? normalizeMetadataField(playbackHash)

            var duration = Double((try await timed("push_total_time") {
                try await playing.total_time()
            }) ?? 0)
            var position = Double((try await timed("push_position") {
                try await playing.position()
            }) ?? 0)
            if duration == 0 || position == 0 {
                if let ref = try await timed(
                    "push_playing_object_ref",
                    seconds: 2.0,
                    { await playing.objectRef() }
                ) {
                    if duration == 0 {
                        let rawTotal = try? await timed("push_ref_total_time") {
                            try await ref.total_time.double()
                        }
                        if let rawTotal {
                            duration = rawTotal
                        }
                    }
                    if position == 0 {
                        let rawPosition = try? await timed("push_ref_position") {
                            try await ref.position.double()
                        }
                        if let rawPosition {
                            position = rawPosition
                        }
                    }
                }
            }

            duration = max(duration, 0)
            position = max(position, 0)

            let marker = makeTrackMarker(
                trackID: trackID,
                title: trimmedTitle,
                artist: artist,
                album: album
            )
            if let marker {
                rememberTrack(host: host, marker: marker)
            }
            rememberPlaybackSnapshot(host: host, marker: marker, position: position, duration: duration)
            lastSuccessfulProtocol[host] = proto

            return .active(
                ATVProps(
                    trackID: trackID,
                    title: trimmedTitle,
                    artist: artist,
                    album: album,
                    position: position,
                    duration: duration
                )
            )
        } catch let timeout as TimeoutError {
            debugLog("[PyatvService] \(timeout.operation) timed out after \(timeout.seconds)s in push update (host=\(host), proto=\(proto))")
            return .ignore
        } catch {
            debugLog("[PyatvService] failed to decode push update (host=\(host), proto=\(proto)): \(error)")
            return .ignore
        }
    }

    private func handlePushUpdate(
        host: String,
        generation: UInt64,
        proto: Pyatv.Const.PyatvProtocol_,
        playstatus: Pyatv.Interface.PlayingInstance
    ) async {
        guard isCurrentPushGeneration(host: host, generation: generation) else { return }

        switch await decodePushUpdate(host: host, proto: proto, playing: playstatus) {
        case .active(let props):
            broadcastPushResult(
                host: host,
                result: ATVFetchResult(connection: .connected, data: props)
            )
        case .inactive:
            broadcastPushResult(
                host: host,
                result: ATVFetchResult(connection: .connected, data: nil)
            )
        case .ignore:
            break
        }
    }

    private func handlePushError(
        host: String,
        generation: UInt64,
        proto: Pyatv.Const.PyatvProtocol_,
        exception: Any
    ) async {
        guard isCurrentPushGeneration(host: host, generation: generation) else { return }
        debugLog("[PyatvService] push updater error (host=\(host), proto=\(proto)): \(exception)")
        await clearPushConnection(host: host)
        broadcastPushResult(
            host: host,
            result: ATVFetchResult(connection: .disconnected, data: nil)
        )
    }

    private func handlePushDisconnect(
        host: String,
        generation: UInt64,
        proto: Pyatv.Const.PyatvProtocol_,
        reason: String,
        details: String?
    ) async {
        guard isCurrentPushGeneration(host: host, generation: generation) else { return }
        if let details {
            debugLog("[PyatvService] push connection ended (host=\(host), proto=\(proto), reason=\(reason)): \(details)")
        } else {
            debugLog("[PyatvService] push connection ended (host=\(host), proto=\(proto), reason=\(reason))")
        }
        await clearPushConnection(host: host)
        broadcastPushResult(
            host: host,
            result: ATVFetchResult(connection: .disconnected, data: nil)
        )
    }

    private func scanConfig(
        host: String,
        protocolType proto: Pyatv.Const.PyatvProtocol_? = nil
    ) async throws -> Pyatv.Interface.BaseconfigInstance? {
        await ensureStorageLoaded()
        if let cached = cachedConfig(for: host) {
            await applyPersistedCredentials(to: cached, host: host)
            return cached
        }
        let configs = try await pyatv.scan(
            loop: loop,
            timeout: 8,
            protocol_: proto,
            hosts: [host],
            storage: storage
        )
        if let config = configs?.first {
            await applyPersistedCredentials(to: config, host: host)
            storeConfig(config, host: host)
            return config
        }
        return nil
    }

    private func preferredProtocol(
        for config: Pyatv.Interface.BaseconfigInstance
    ) async -> Pyatv.Const.PyatvProtocol_ {
        do {
            if let _ = try await config.get_service(protocol_: .companion) {
                return .companion
            }
        } catch {}
        return .airPlay
    }

    private func credentialsFromSettings(
        config: Pyatv.Interface.BaseconfigInstance,
        host: String,
        proto: Pyatv.Const.PyatvProtocol_
    ) async -> String? {
        if let storage {
            do {
                let settings = try await storage.get_settings(config: config)
                if let settings,
                   let jsonRef = try await settings.model_dump_json() {
                    let namespace = await executor.makeNamespace(callables: [:])
                    try await namespace.payload.setValue(jsonRef)
                    let jsonString = try await namespace.payload.string()
                    if let data = jsonString.data(using: .utf8),
                       let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let protocols = obj["protocols"] as? [String: Any] {
                        let rawKey = proto.rawValue
                        let candidates = [rawKey, rawKey.lowercased()]
                        for key in candidates {
                            if let entry = protocols[key] as? [String: Any],
                               let credentials = entry["credentials"] as? String,
                               !credentials.isEmpty {
                                return credentials
                            }
                        }
                    }
                }
            } catch {
                debugLog("[PyatvService] Failed to read credentials: \(error)")
            }
        }
        return await persistedCredentials(for: config, host: host, proto: proto)
    }

    private func canFetchMetadata(
        from atv: Pyatv.Interface.AppletvInstance,
        host: String,
        proto: Pyatv.Const.PyatvProtocol_
    ) async -> Bool {
        if await isBlocking(atv, host: host, proto: proto, context: "features") {
            return false
        }
        guard let features = try? await withTimeout(
            seconds: 3,
            operation: "features",
            {
                try await atv.features()
            }
        ) else {
            debugLog("[PyatvService] metadata feature check failed (host=\(host), proto=\(proto))")
            return false
        }

        let states: [Pyatv.Const.PyatvFeaturestate] = [.available]
        let titleAvailable = (try? await withTimeout(
            seconds: 2,
            operation: "title_feature_state",
            {
                try await features.in_state(
                    states: states,
                    Pyatv.Const.PyatvFeaturename.title
                )
            }
        )) ?? false

        if !titleAvailable {
            debugLog("[PyatvService] metadata feature unavailable (host=\(host), proto=\(proto))")
        }

        return titleAvailable
    }

    /// Fetch now-playing metadata for the given Apple TV host.
    /// Returns connection state and optional metadata.
    func getATVProps(
        host: String
    ) async -> ATVFetchResult {
        enum FetchOutcome {
            case connected(ATVProps?)
            case failed
        }

        func fetchWithProtocol(
            _ proto: Pyatv.Const.PyatvProtocol_,
            config: Pyatv.Interface.BaseconfigInstance
        ) async -> FetchOutcome {
            func timed<T>(
                _ operation: String,
                seconds: Double = 2.5,
                _ work: @escaping () async throws -> T
            ) async throws -> T {
                try await self.withTimeout(seconds: seconds, operation: operation, work)
            }

            var didConnect = false
            let connKey = connectionKey(host: host, proto: proto)
            do {
                let atv: Pyatv.Interface.AppletvInstance
                if let cached = await cachedConnection(host: host, proto: proto) {
                    atv = cached
                    didConnect = true
                    debugLog("[PyatvService] reusing connection (host=\(host), proto=\(proto))")
                } else {
                    debugLog("[PyatvService] connecting (host=\(host), proto=\(proto))")
                    let connected = try await withTimeout(seconds: 8, operation: "connect") {
                        try await self.pyatv.connect(
                            config: config,
                            loop: self.loop,
                            protocol_: proto,
                            storage: self.storage
                        )
                    }
                    guard let connected else {
                        debugLog("[PyatvService] connect returned nil (host=\(host), proto=\(proto))")
                        _ = await availableProtocols(for: config)
                        return .failed
                    }
                    atv = connected
                    didConnect = true
                    storeConnection(atv, host: host, proto: proto)
                }

                if await isBlocking(atv, host: host, proto: proto, context: "pre-metadata") {
                    await closeConnection(forKey: connKey)
                    return .failed
                }

                if !(await canFetchMetadata(from: atv, host: host, proto: proto)) {
                    return .connected(nil)
                }

                debugLog("[PyatvService] fetching metadata (host=\(host), proto=\(proto))")
                let metadata = try await withTimeout(seconds: 6, operation: "metadata") {
                    try await atv.metadata()
                }
                guard let metadata else {
                    debugLog("[PyatvService] metadata is nil (host=\(host), proto=\(proto))")
                    await closeConnection(forKey: connKey)
                    return .connected(nil)
                }
                if await isBlocking(atv, host: host, proto: proto, context: "playing") {
                    await closeConnection(forKey: connKey)
                    return .failed
                }
                let playing = try await withTimeout(seconds: 6, operation: "playing") {
                    try await metadata.playing()
                }
                guard let playing else {
                    debugLog("[PyatvService] playing is nil (host=\(host), proto=\(proto))")
                    await closeConnection(forKey: connKey)
                    return .connected(nil)
                }

                let title = (try await timed("title") { try await playing.title() }) ?? ""
                let artist = try await timed("artist") { try await playing.artist() }
                let album = try await timed("album") { try await playing.album() }
                let itunesId = try await timed("itunes_store_identifier") { try await playing.itunes_store_identifier() }
                let contentIdentifier = try await timed("content_identifier") { try await playing.content_identifier() }
                let playbackHash = try await timed("playback_hash") { try await playing.hash() }
                let trackID = itunesId.flatMap { $0 > 0 ? String($0) : nil }
                    ?? normalizeMetadataField(contentIdentifier)
                    ?? normalizeMetadataField(playbackHash)
                let marker = makeTrackMarker(trackID: trackID, title: title, artist: artist, album: album)
                let trackChanged = marker.map { didTrackChange(host: host, marker: $0) } ?? false

                let deviceState = try? await timed("device_state", seconds: 2.0) {
                    try await playing.device_state()
                }
                if let deviceState {
                    debugLog("[PyatvService] device_state=\(deviceState) (host=\(host), proto=\(proto))")
                } else {
                    debugLog("[PyatvService] device_state=nil; applying fallback playback checks (host=\(host), proto=\(proto))")
                }

                // HomePod can briefly report transitional states while the next track metadata
                // is already available. If track marker changed, allow it through.
                if let deviceState {
                    if deviceState != .playing && deviceState != .seeking {
                        if trackChanged {
                            debugLog("[PyatvService] allowing metadata in non-playing state due to track change (host=\(host), proto=\(proto))")
                        } else {
                            await closeConnection(forKey: connKey)
                            return .connected(nil)
                        }
                    }
                }

                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedTitle.isEmpty {
                    debugLog("[PyatvService] title is empty (host=\(host), proto=\(proto))")
                    await closeConnection(forKey: connKey)
                    return .connected(nil)
                }

                var duration = Double((try await timed("total_time", seconds: 2.0) {
                    try await playing.total_time()
                }) ?? 0)
                var position = Double((try await timed("position", seconds: 2.0) {
                    try await playing.position()
                }) ?? 0)
                if duration == 0 || position == 0 {
                    if let ref = try await timed("playing_object_ref", seconds: 2.0, { await playing.objectRef() }) {
                        if duration == 0, let rawTotal = try? await timed(
                            "ref_total_time",
                            seconds: 2.0,
                            {
                                try await ref.total_time.double()
                            }
                        ) {
                            duration = rawTotal
                        }
                        if position == 0, let rawPosition = try? await timed(
                            "ref_position",
                            seconds: 2.0,
                            {
                                try await ref.position.double()
                            }
                        ) {
                            position = rawPosition
                        }
                    }
                }
                duration = max(duration, 0)
                position = max(position, 0)
                if shouldDiscardLikelyStaleRemoteSnapshot(
                    host: host,
                    marker: marker,
                    position: position,
                    duration: duration
                ) {
                    debugLog("[PyatvService] discarding likely stale same-track snapshot after remote transition (host=\(host), proto=\(proto))")
                    await closeConnection(forKey: connKey)
                    return .connected(nil)
                }
                if deviceState == nil,
                   shouldTreatNilStateAsInactive(
                    host: host,
                    marker: marker,
                    position: position,
                    duration: duration
                   ) {
                    debugLog("[PyatvService] treating nil-state stagnant playback as inactive (host=\(host), proto=\(proto))")
                    await closeConnection(forKey: connKey)
                    return .connected(nil)
                }
                if let marker {
                    rememberTrack(host: host, marker: marker)
                }
                rememberPlaybackSnapshot(host: host, marker: marker, position: position, duration: duration)
                lastSuccessfulProtocol[host] = proto

                return .connected(ATVProps(
                    trackID: trackID,
                    title: trimmedTitle,
                    artist: artist,
                    album: album,
                    position: position,
                    duration: duration
                ))
            } catch let timeout as TimeoutError {
                debugLog("[PyatvService] \(timeout.operation) timed out after \(timeout.seconds)s (host=\(host), proto=\(proto))")
                await closeConnection(forKey: connKey)
                return didConnect ? .connected(nil) : .failed
            } catch {
                debugLog("[PyatvService] fetch failed (host=\(host), proto=\(proto)): \(error)")
                await closeConnection(forKey: connKey)
                return didConnect ? .connected(nil) : .failed
            }
        }

        do {
            if hasPushSubscribers(host: host) {
                ensurePushSupervisor(host: host)
                if let pushed = bridgedPushResultForPolling(host: host) {
                    return pushed
                }
            }

            let config = try await withTimeout(seconds: 8, operation: "scan") {
                try await self.scanConfig(host: host)
            }
            guard let config else {
                debugLog("[PyatvService] scan returned no config (host=\(host))")
                return ATVFetchResult(connection: .disconnected, data: nil)
            }

            let name = (try? await config.name()) ?? "unknown"
            let identifier = (try? await config.identifier()) ?? "unknown"
            debugLog("[PyatvService] scan result host=\(host) name=\(name) id=\(identifier)")
            let available = await availableProtocols(for: config)
            let fallbackProtocols = fetchProtocolOrder(host: host, available: available)
            var connected = false
            for proto in fallbackProtocols {
                let outcome = await fetchWithProtocol(proto, config: config)
                switch outcome {
                case .connected(let data):
                    connected = true
                    if let data {
                        return ATVFetchResult(connection: .connected, data: data)
                    }
                case .failed:
                    continue
                }
            }
            return ATVFetchResult(
                connection: connected ? .connected : .disconnected,
                data: nil
            )
        } catch let timeout as TimeoutError {
            debugLog("[PyatvService] \(timeout.operation) timed out after \(timeout.seconds)s (host=\(host))")
            return ATVFetchResult(connection: .disconnected, data: nil)
        } catch {
            debugLog("[PyatvService] Failed to fetch ATV props: \(error)")
            return ATVFetchResult(connection: .disconnected, data: nil)
        }
    }

    func makePushStream(host: String) async -> AsyncStream<ATVFetchResult> {
        AsyncStream(
            ATVFetchResult.self,
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            let id = UUID()

            Task {
                self.addPushSubscriber(
                    host: host,
                    id: id,
                    continuation: continuation
                )
            }

            continuation.onTermination = { _ in
                Task {
                    await self.removePushSubscriber(host: host, id: id)
                }
            }
        }
    }

    /// Asynchronously begin pairing (shows PIN on device).
    func pairDeviceBegin(host: String) async -> Bool {
        return await pairDeviceBeginSync(host: host)
    }

    /// Synchronous begin pairing.
    func pairDeviceBeginSync(host: String) async -> Bool {
        do {
            guard let config = try await scanConfig(host: host) else { return false }
            let proto = await preferredProtocol(for: config)
            guard let handler = try await pyatv.pair(
                config: config,
                protocol_: proto,
                loop: loop,
                storage: storage,
                kwargs: ["name": "Applepie-RPC"]
            ) else {
                return false
            }

            do {
                try await handler.begin()
            } catch {
                try? await handler.close()
                debugLog("[PyatvService] Pairing begin failed: \(error)")
                return false
            }

            pairings[host] = PairingSession(handler: handler, config: config, proto: proto)
            return true
        } catch {
            debugLog("[PyatvService] Pairing begin error: \(error)")
            return false
        }
    }

    /// Asynchronously finish pairing with PIN.
    func pairDeviceFinish(host: String, pin: Int) async -> String? {
        return await pairDeviceFinishSync(host: host, pin: pin)
    }

    /// Synchronous finish pairing.
    func pairDeviceFinishSync(host: String, pin: Int) async -> String? {
        guard let session = pairings.removeValue(forKey: host) else {
            debugLog("[PyatvService] No pairing session for host \(host)")
            return nil
        }
        defer {
            Task { try? await session.handler.close() }
        }

        do {
            try await session.handler.pin(pin: pin)
            try await session.handler.finish()

            let paired = (try await session.handler.has_paired()) ?? false
            guard paired else { return nil }

            if let storage {
                try? await storage.save()
            }

            guard let credentials = await credentialsFromSettings(
                config: session.config,
                host: host,
                proto: session.proto
            ) else {
                return nil
            }
            _ = try? await session.config.set_credentials(protocol_: session.proto, credentials: credentials)
            await persistCredentials(
                credentials,
                for: session.config,
                host: host,
                proto: session.proto
            )
            return credentials
        } catch {
            debugLog("[PyatvService] Pairing finish failed: \(error)")
            return nil
        }
    }

    /// Check whether pairing is mandatory for the given host.
    func isPairingNeeded(host: String) async -> Bool {
        do {
            guard let config = try await scanConfig(host: host) else { return false }
            let proto = await preferredProtocol(for: config)

            if let credentials = await credentialsFromSettings(config: config, host: host, proto: proto),
               !credentials.isEmpty {
                _ = try? await config.set_credentials(protocol_: proto, credentials: credentials)
                return false
            }

            guard let service = try await config.get_service(protocol_: proto) else { return false }
            let pairingRequirement = try await service.pairing()
            let requiresPassword = (try await service.requires_password()) ?? false

            if proto == .airPlay {
                return pairingRequirement == .mandatory && requiresPassword
            }
            return pairingRequirement == .mandatory
        } catch {
            debugLog("[PyatvService] Pairing check failed: \(error)")
            return false
        }
    }

    /// Remove cached pairing.
    func removePairing() async -> Bool {
        let hadPersistedCredentials = !persistedCredentialStore.credentialsByKey.isEmpty
        let hadLegacyStorage = FileManager.default.fileExists(atPath: legacyStorageURL.path)
        var clearedInMemory = false
        do {
            if let storage {
                try await storage.load()
                let settings = (try await storage.settings()) ?? []
                for item in settings {
                    _ = (try await storage.remove_settings(settings: item)) ?? false
                }
                try await storage.save()
            }
            clearedInMemory = true
        } catch {
            debugLog("[PyatvService] Failed to remove pairing: \(error)")
        }

        clearPersistedCredentials()
        return clearedInMemory || hadPersistedCredentials || hadLegacyStorage
    }

    /// Clears pairing credentials and drops all in-memory caches/connections.
    /// This is stronger than `removePairing()` because it also closes cached connections so the
    /// next fetch can't reuse an already-authenticated session.
    func clearCache() async -> Bool {
        // Close any in-flight pairing handlers.
        for (_, session) in pairings {
            _ = try? await session.handler.close()
        }
        pairings.removeAll()

        // Close cached connections to avoid "still connected" behavior after clearing credentials.
        for (_, cached) in connectionCache {
            _ = try? await cached.atv.close()
        }
        connectionCache.removeAll()
        configCache.removeAll()
        lastSuccessfulProtocol.removeAll()
        lastEmittedTrackByHost.removeAll()
        lastPlaybackSnapshotByHost.removeAll()
        nilStateStagnationCountByHost.removeAll()
        for host in Array(pushSessions.keys) {
            await stopPushSession(host: host)
        }
        pushSessions.removeAll()

        var ok = false
        if let storage {
            do {
                try await storage.load()
                let settings = (try await storage.settings()) ?? []
                for item in settings {
                    _ = try await storage.remove_settings(settings: item)
                }
                try await storage.save()
                ok = true
            } catch {
                debugLog("[PyatvService] Failed to clear pairing via storage: \(error)")
            }
        }

        let hadPersistedCredentials = !persistedCredentialStore.credentialsByKey.isEmpty
        let hadLegacyStorage = FileManager.default.fileExists(atPath: legacyStorageURL.path)
        clearPersistedCredentials()
        if let storage {
            try? await storage.load()
        }
        ok = ok || hadPersistedCredentials || hadLegacyStorage

        return ok
    }

    /// Cancel pairing.
    func cancelPairing(host: String) async -> Bool {
        guard let session = pairings.removeValue(forKey: host) else {
            return false
        }
        do {
            try await session.handler.close()
            _ = await removePairing()
            return true
        } catch {
            debugLog("[PyatvService] Failed to cancel pairing: \(error)")
            return false
        }
    }
}

extension PyatvService: ATVServiceProviding {}
