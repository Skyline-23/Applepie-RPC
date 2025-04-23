//
//  PythonActor.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/23/25.
//

import Foundation
import PythonKit
import Dispatch

public final class PythonExecutor {
    private let queue = DispatchQueue(label: "com.applepie.pythonQueue", qos: .userInitiated)
    private var modules: [String: PythonObject] = [:]

    /// Embedded Python runtime setup
    public func setupEnvironment() {
        queue.sync {
            // Initialize embedded Python via PythonKit
            guard let frameworksURL = Bundle.main.privateFrameworksURL else {
                print("Frameworks URL not found")
                return
            }
            // Point to libpython3.12.dylib
            let libPath = frameworksURL
                .appendingPathComponent("Python.framework")
                .appendingPathComponent("Versions/3.12")
                .appendingPathComponent("Python")
            PythonLibrary.useLibrary(at: libPath.path(percentEncoded: false))

            // Set PYTHONHOME to embedded python location
            let pythonHome = frameworksURL
                .appendingPathComponent("Python.framework")
                .appendingPathComponent("Versions/3.12")
            setenv("PYTHONHOME", pythonHome.path, 1)
            
            // Add embedded C‑extension modules to Python path
            let dynloadPath = Bundle.main.resourceURL!
                .appendingPathComponent("PythonSupport/lib-dynload").path
            let sys = Python.import("sys")
            sys.path.insert(0, dynloadPath)
            
            let stdlibPath = Bundle.main.resourceURL!
              .appendingPathComponent("PythonSupport/python/lib/python3.12").path
            sys.path.insert(1, stdlibPath)

            // Add pip-installed site-packages path
            let sitePackages = Bundle.main.resourceURL!
              .appendingPathComponent("PythonSupport/python/lib/python3.12/site-packages").path
            sys.path.insert(2, sitePackages)
            
            // Include the app’s resource directory to locate bundled Python scripts (e.g., discord_service.py)
            if let resourcesPath = Bundle.main.resourceURL?.path {
                sys.path.insert(3, resourcesPath)
            }
        }
    }

    /// Import and cache a Python module
    public func importModule(named name: String) {
        queue.sync {
            modules[name] = Python.import(name)
        }
    }

    /// Retrieve a cached module
    public func module(named name: String) -> PythonObject? {
        return queue.sync { modules[name] }
    }
}



/// Actor responsible for importing modules and providing access to them.
public actor PythonModuleActor {
    private let executor: PythonExecutor

    public init(executor: PythonExecutor) {
        self.executor = executor
    }

    public func importModule(named name: String) {
        executor.importModule(named: name)
    }

    public func module(named name: String) -> PythonObject? {
        return executor.module(named: name)
    }
}
