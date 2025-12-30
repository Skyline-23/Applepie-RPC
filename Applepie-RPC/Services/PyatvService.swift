//
//  PyatvService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/25/25.
//

import Foundation
import PylibKit_Mac

/// Service to fetch Apple TV now-playing info using PylibKit's pyatv bindings.
class PyatvService {
    private struct PairingSession {
        let handler: Pyatv.Interface.PairinghandlerInstance
        let config: Pyatv.Interface.BaseconfigInstance
        let proto: Pyatv.Const.PyatvProtocol_
    }

    private let executor: PythonExecutor
    private let pyatv: Pyatv.PyatvService
    private let loop: AsyncioLoop
    private let storage: Pyatv.Interface.StorageInstance?
    private var pairings: [String: PairingSession] = [:]

    /// Factory to create and set up PyatvService.
    static func create(executor: PythonExecutor) async -> PyatvService {
        let pyatv = await Pyatv.PyatvService.create(executor: executor)
        let loop = await executor.createAsyncioLoop()

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
            print("[PyatvService] Failed to initialize storage: \(error)")
        }

        return PyatvService(executor: executor, pyatv: pyatv, loop: loop, storage: storage)
    }

    private init(
        executor: PythonExecutor,
        pyatv: Pyatv.PyatvService,
        loop: AsyncioLoop,
        storage: Pyatv.Interface.StorageInstance?
    ) {
        self.executor = executor
        self.pyatv = pyatv
        self.loop = loop
        self.storage = storage
    }

    private func ensureStorageLoaded() async {
        guard let storage else { return }
        do {
            try await storage.load()
        } catch {
            print("[PyatvService] Storage load failed: \(error)")
        }
    }

    private func scanConfig(
        host: String,
        protocolType proto: Pyatv.Const.PyatvProtocol_? = nil
    ) async throws -> Pyatv.Interface.BaseconfigInstance? {
        await ensureStorageLoaded()
        let configs = try await pyatv.scan(
            loop: loop,
            timeout: 5,
            protocol_: proto,
            hosts: [host],
            storage: storage
        )
        return configs?.first
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
            let jsonString: String = try executor.coerce(jsonRef)
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
            print("[PyatvService] Failed to read credentials: \(error)")
        }
        return nil
    }

    /// Fetch now-playing metadata for the given Apple TV host.
    /// Returns (trackID, title, artist, album, position, duration) or nil if unavailable.
    func getATVProps(
        host: String
    ) async -> (trackID: String?, title: String, artist: String?, album: String?, position: Double, duration: Double)? {
        do {
            guard let config = try await scanConfig(host: host, protocolType: .airPlay) else {
                return nil
            }
            guard let atv = try await pyatv.connect(
                config: config,
                loop: loop,
                protocol_: .airPlay,
                storage: storage
            ) else {
                return nil
            }
            defer {
                Task { try? await atv.close() }
            }

            guard let metadata = try await atv.metadata() else { return nil }
            guard let playing = try await metadata.playing() else { return nil }

            if let state = try await playing.device_state() {
                if state == .idle || state == .pauEd {
                    return nil
                }
            }

            let title = (try await playing.title()) ?? ""
            if title.isEmpty {
                return nil
            }

            let artist = try await playing.artist()
            let album = try await playing.album()
            let duration = Double((try await playing.total_time()) ?? 0)
            let position = Double((try await playing.position()) ?? 0)
            let itunesId = try await playing.itunes_store_identifier()
            let trackID = itunesId.map { String($0) }

            return (
                trackID: trackID,
                title: title,
                artist: artist,
                album: album,
                position: position,
                duration: duration
            )
        } catch {
            print("[PyatvService] Failed to fetch ATV props: \(error)")
            return nil
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
                print("[PyatvService] Pairing begin failed: \(error)")
                return false
            }

            pairings[host] = PairingSession(handler: handler, config: config, proto: proto)
            return true
        } catch {
            print("[PyatvService] Pairing begin error: \(error)")
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
            print("[PyatvService] No pairing session for host \(host)")
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
            print("[PyatvService] Pairing finish failed: \(error)")
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
            print("[PyatvService] Pairing check failed: \(error)")
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
            print("[PyatvService] Failed to remove pairing: \(error)")
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
            print("[PyatvService] Failed to cancel pairing: \(error)")
            return false
        }
    }
}
