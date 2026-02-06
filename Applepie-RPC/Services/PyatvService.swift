//
//  PyatvService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/25/25.
//

import Foundation
import PylibKit_Mac

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

    private let executor: PythonExecutor
    private let pyatv: Pyatv.PyatvService
    private let loop: AsyncioLoop
    private let storage: Pyatv.Interface.StorageInstance?
    private let shield: Pyatv.Support.Shield.ShieldService
    private var pairings: [String: PairingSession] = [:]
    private var configCache: [String: CachedConfig] = [:]
    private var connectionCache: [String: CachedConnection] = [:]
    private var lastSuccessfulProtocol: [String: Pyatv.Const.PyatvProtocol_] = [:]
    private let configTTL: TimeInterval = 60
    private let connectionTTL: TimeInterval = 30

    /// Factory to create and set up PyatvService.
    static func create(executor: PythonExecutor) async -> PyatvService {
        let pyatv = await Pyatv.PyatvService.create(executor: executor)
        let loop = await executor.createAsyncioLoop()
        let shield = await Pyatv.Support.Shield.ShieldService.create(executor: executor)

        var storage: Pyatv.Interface.StorageInstance? = nil
        do {
            let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let appDir = (baseDir ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("Applepie-RPC", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            let storageURL = appDir.appendingPathComponent("pyatv_storage.json")

            let fileStorage = try await Pyatv.Storage.FileStorage.FilestorageInstance.create(
                executor: executor,
                filename: storageURL.path,
                loop: loop
            )
            try await fileStorage.load()
            if let ref = await fileStorage.objectRef() {
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
            shield: shield
        )
    }

    private init(
        executor: PythonExecutor,
        pyatv: Pyatv.PyatvService,
        loop: AsyncioLoop,
        storage: Pyatv.Interface.StorageInstance?,
        shield: Pyatv.Support.Shield.ShieldService
    ) {
        self.executor = executor
        self.pyatv = pyatv
        self.loop = loop
        self.storage = storage
        self.shield = shield
    }

    private func ensureStorageLoaded() async {
        guard let storage else { return }
        do {
            try await storage.load()
        } catch {
            debugLog("[PyatvService] Storage load failed: \(error)")
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
            try? await cached.atv.close()
        }
    }

    private func scanConfig(
        host: String,
        protocolType proto: Pyatv.Const.PyatvProtocol_? = nil
    ) async throws -> Pyatv.Interface.BaseconfigInstance? {
        await ensureStorageLoaded()
        if let cached = cachedConfig(for: host) {
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
            storeConfig(config, host: host)
            return config
        }
        return nil
    }

    private func preferredProtocol(
        for config: Pyatv.Interface.BaseconfigInstance
    ) async -> Pyatv.Const.PyatvProtocol_ {
        if let service = try? await config.get_service(protocol_: .companion), service != nil {
            return .companion
        }
        return .airPlay
    }

    private func credentialsFromSettings(
        config: Pyatv.Interface.BaseconfigInstance,
        proto: Pyatv.Const.PyatvProtocol_
    ) async -> String? {
        guard let storage else { return nil }
        do {
            let settings = try await storage.get_settings(config: config)
            guard let settings else { return nil }
            guard let jsonRef = try await settings.model_dump_json() else { return nil }
            let namespace = await executor.makeNamespace(callables: [:])
            try await namespace.payload.setValue(jsonRef)
            let jsonString = try await namespace.payload.string()
            guard let data = jsonString.data(using: .utf8) else { return nil }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            guard let protocols = obj["protocols"] as? [String: Any] else { return nil }

            let rawKey = proto.rawValue
            let candidates = [rawKey, rawKey.lowercased()]
            for key in candidates {
                if let entry = protocols[key] as? [String: Any],
                   let credentials = entry["credentials"] as? String,
                   !credentials.isEmpty {
                    return credentials
                }
            }
        } catch {
            debugLog("[PyatvService] Failed to read credentials: \(error)")
        }
        return nil
    }

    private func canFetchMetadata(
        from atv: Pyatv.Interface.AppletvInstance,
        host: String,
        proto: Pyatv.Const.PyatvProtocol_
    ) async -> Bool {
        if await isBlocking(atv, host: host, proto: proto, context: "features") {
            return false
        }
        guard let features = try? await atv.features() else {
            debugLog("[PyatvService] metadata feature check failed (host=\(host), proto=\(proto))")
            return false
        }

        let states: [Pyatv.Const.PyatvFeaturestate] = [.available]
        let titleAvailable = (try? await features.in_state(
            states: states,
            Pyatv.Const.PyatvFeaturename.title
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

        func availableProtocols(config: Pyatv.Interface.BaseconfigInstance) async -> [Pyatv.Const.PyatvProtocol_] {
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

        func fetchWithProtocol(
            _ proto: Pyatv.Const.PyatvProtocol_,
            config: Pyatv.Interface.BaseconfigInstance
        ) async -> FetchOutcome {
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
                        _ = await availableProtocols(config: config)
                        return .failed
                    }
                    atv = connected
                    didConnect = true
                    storeConnection(atv, host: host, proto: proto)
                }
                lastSuccessfulProtocol[host] = proto

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
                    return .connected(nil)
                }

                if let state = try await playing.device_state() {
                    if state == .idle || state == .pauEd || state == .stopped {
                        debugLog("[PyatvService] device_state=\(state) (host=\(host), proto=\(proto))")
                        return .connected(nil)
                    }
                    debugLog("[PyatvService] device_state=\(state) (host=\(host), proto=\(proto))")
                }

                let title = (try await playing.title()) ?? ""
                if title.isEmpty {
                    debugLog("[PyatvService] title is empty (host=\(host), proto=\(proto))")
                    return .connected(nil)
                }

                let artist = try await playing.artist()
                let album = try await playing.album()
                var duration = Double((try await playing.total_time()) ?? 0)
                var position = Double((try await playing.position()) ?? 0)
                if duration == 0 || position == 0 {
                    if let ref = await playing.objectRef() {
                        if duration == 0, let rawTotal = try? await ref.total_time.double() {
                            duration = rawTotal
                        }
                        if position == 0, let rawPosition = try? await ref.position.double() {
                            position = rawPosition
                        }
                    }
                }
                let itunesId = try await playing.itunes_store_identifier()
                let trackID = itunesId.flatMap { $0 > 0 ? String($0) : nil }

                if duration <= 0 {
                    debugLog("[PyatvService] duration unavailable (host=\(host), proto=\(proto))")
                    return .connected(nil)
                }

                return .connected(ATVProps(
                    trackID: trackID,
                    title: title,
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
            let available = await availableProtocols(config: config)
            var desiredOrder: [Pyatv.Const.PyatvProtocol_] = []
            if let lastProto = lastSuccessfulProtocol[host] {
                desiredOrder.append(lastProto)
            }
            desiredOrder.append(contentsOf: [.mRP, .companion, .airPlay])
            var seen = Set<String>()
            let ordered = desiredOrder.filter { proto in
                let key = proto.rawValue
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
            let protocolsToTry = ordered.filter { available.contains($0) }
            let fallbackProtocols = protocolsToTry.isEmpty ? ordered : protocolsToTry
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

            return await credentialsFromSettings(config: session.config, proto: session.proto)
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

            if let credentials = await credentialsFromSettings(config: config, proto: proto), !credentials.isEmpty {
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
        guard let storage else { return false }
        do {
            try await storage.load()
            let settings = (try await storage.settings()) ?? []
            var removedAny = false
            for item in settings {
                let removed = (try await storage.remove_settings(settings: item)) ?? false
                removedAny = removedAny || removed
            }
            try await storage.save()
            return removedAny || !settings.isEmpty
        } catch {
            debugLog("[PyatvService] Failed to remove pairing: \(error)")
            return false
        }
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
