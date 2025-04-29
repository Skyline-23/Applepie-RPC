//
//  PyatvService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/25/25.
//

import Foundation
import PythonKit

/// Service to fetch Apple TV now-playing info using the Python pyatv_service module.
class PyatvService: PythonService {
    private var atvPropsFunc: PythonObject? = nil
    private var pairDeviceSyncFunc: PythonObject? = nil
    private var pairDeviceBeginFunc: PythonObject? = nil
    private var pairDeviceBeginSyncFunc: PythonObject? = nil
    private var pairDeviceFinishFunc: PythonObject? = nil
    private var pairDeviceFinishSyncFunc: PythonObject? = nil
    private var isPairingNeededSyncFunc: PythonObject? = nil
    private var removePairingSyncFunc: PythonObject? = nil
    
    /// Factory to create and set up PyatvService on the Python thread.
    static public func create(executor: PythonExecutor) async -> PyatvService {
        // 1) Instantiate on Python thread
        let service = await executor.createOnPythonThread {
            PyatvService(executor: executor)
        }
        // 2) Import the pyatv_service module
        await executor.importModule(named: "pyatv_service")
        if let mod = await executor.module(named: "pyatv_service") {
            // Cache the synchronous ATV props function
            await executor.performAsync { [service] in
                service.atvPropsFunc = mod.get_atv_props_sync
            }
            await executor.performAsync { [service] in
                service.pairDeviceBeginSyncFunc = mod.pair_device_begin_sync
                service.pairDeviceFinishSyncFunc = mod.pair_device_finish_sync
                service.isPairingNeededSyncFunc = mod.is_pairing_needed_sync
                service.removePairingSyncFunc = mod.remove_pairing_sync
            }
            print("[PyatvService] Imported pyatv_service module")
        }
        return service
    }
    
    /// Synchronous initializer kept minimal; real setup in `create`
    override init(executor: PythonExecutor) {
        super.init(executor: executor)
    }
    
    /// Fetch now-playing metadata for the given Apple TV host.
    /// Returns (trackID, title, artist, album, position, duration) or nil if unavailable.
    func getATVProps(host: String) async -> (trackID: String?, title: String, artist: String?, album: String?, position: Double, duration: Double)? {
        guard let atvPropsFunc = atvPropsFunc else {
            print("[PyatvService] atv_props function is not initialized")
            return nil
        }
        // Fetch and convert in Python thread
        return await callPython { () -> (trackID: String?, title: String, artist: String?, album: String?, position: Double, duration: Double)? in
            // Invoke Python and build Swift tuple entirely inside Python thread
            let result = atvPropsFunc(host)
            // Check for None
            if result != Python.None {
                // Manually build Swift dictionary from Python dict items
                guard let dict = Dictionary<String, PythonObject>(result) else { return nil }
                let trackID = dict["itunes_id"]?.description
                let title   = dict["title"]?.description ?? ""
                let artist  = dict["artist"]?.description
                let album   = dict["album"]?.description
                let position = Double(dict["position"]?.description ?? "") ?? 0.0
                let duration = Double(dict["duration"]?.description ?? "") ?? 0.0
                return (trackID: trackID,
                        title: title,
                        artist: artist,
                        album: album,
                        position: position,
                        duration: duration)
            } else {
                return nil
            }
        }
    }
    
    /// Asynchronously begin pairing (shows PIN on device).
    func pairDeviceBegin(host: String) async -> Bool {
        guard let f = pairDeviceBeginSyncFunc else {
            print("[PyatvService] pair_device_begin_sync function is not initialized")
            return false
        }
        return await callPython { () -> Bool in
            let result = f(host)
            return Bool(result) ?? false
        }
    }
    
    /// Synchronous begin pairing.
    func pairDeviceBeginSync(host: String) async -> Bool {
        guard let f = pairDeviceBeginSyncFunc else {
            print("[PyatvService] pair_device_begin_sync function is not initialized")
            return false
        }
        return await callPython { () -> Bool in
            let result = f(host)
            return Bool(result) ?? false
        }
    }
    
    /// Asynchronously finish pairing with PIN.
    func pairDeviceFinish(host: String, pin: Int) async -> String? {
        guard let f = pairDeviceFinishSyncFunc else {
            print("[PyatvService] pair_device_finish_sync function is not initialized")
            return nil
        }
        return await callPython { () -> String? in
            let result = f(host, pin)
            return result == Python.None ? nil : String(result)
        }
    }
    
    /// Synchronous finish pairing.
    func pairDeviceFinishSync(host: String, pin: Int) async -> String? {
        guard let f = pairDeviceFinishSyncFunc else {
            print("[PyatvService] pair_device_finish_sync function is not initialized")
            return nil
        }
        return await callPython { () -> String? in
            let result = f(host, pin)
            return result == Python.None ? nil : String(result)
        }
        
    }
    
    /// Check whether pairing is mandatory for the given host.
    func isPairingNeeded(host: String) async -> Bool {
        guard let f = isPairingNeededSyncFunc else {
            print("[PyatvService] is_pairing_needed_sync function is not initialized")
            return false
        }
        return await callPython { () -> Bool in
            let result = f(host)
            return Bool(result) ?? false
        }
    }
    
    /// Remove cached pairing.
    func removePairing() async -> Bool {
        guard let f = removePairingSyncFunc else {
            print("[PyatvService] remove_pairing_sync function is not initialized")
            return false
        }
        return await callPython { () -> Bool in
            let result = f()
            return Bool(result) ?? false
        }
    }
}
