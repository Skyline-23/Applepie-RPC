//
//  PythonExecutor.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/23/25.
//

import Foundation
import PythonKit

public final class PythonExecutor {
    private let pythonThread: Thread = {
        let t = Thread {
            Thread.current.name = "PythonKitThread"
            let runLoop = RunLoop.current
            runLoop.add(Port(), forMode: .default)
            runLoop.run()
        }
        t.start()
        return t
    }()
    private var modules: [String: PythonObject] = [:]

    private class BlockWrapper: NSObject {
        let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
        @objc func invoke() { block() }
    }

    /// Run the given block on the Python thread and return its result asynchronously.
    public func performAsync<T>(_ block: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            let wrapper = BlockWrapper {
                let result = block()
                cont.resume(returning: result)
            }
            wrapper.perform(
                #selector(BlockWrapper.invoke),
                on: pythonThread,
                with: nil,
                waitUntilDone: false
            )
        }
    }

    /// Create an object on the Python thread and return it asynchronously.
    public func createOnPythonThread<T>(_ block: @escaping () -> T) async -> T {
        return await performAsync(block)
    }

    /// Embedded Python runtime setup
    public func setupEnvironment() async {
        await performAsync {
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
            
            // Add C‑extension modules directory from embedded framework
            let version = "3.12"
            let frameworkLib = frameworksURL
                .appendingPathComponent("Python.framework")
                .appendingPathComponent("Versions/\(version)")
            let dynloadPath = frameworkLib
                .appendingPathComponent("lib/python\(version)/lib-dynload").path
            let sys = Python.import("sys")
            sys.path.insert(0, dynloadPath)

            // Add standard library from embedded framework
            let stdlibPath = frameworkLib
                .appendingPathComponent("lib/python\(version)").path
            sys.path.insert(1, stdlibPath)

            // Add site-packages from embedded framework
            let sitePackages = frameworkLib
                .appendingPathComponent("lib/python\(version)/site-packages").path
            sys.path.insert(2, sitePackages)
            
            // Include the app’s resource directory to locate bundled Python scripts (e.g., discord_service.py)
            if let resourcesPath = Bundle.main.resourceURL?.appendingPathComponent("Applepie-RPC-core").path {
                sys.path.insert(3, resourcesPath)
            }
        }
    }

    /// Import and cache a Python module
    public func importModule(named name: String) async {
        await performAsync { [self] in
            self.modules[name] = Python.import(name)
        }
    }

    /// Retrieve a cached module
    public func module(named name: String) async -> PythonObject? {
        return await performAsync { [self] in
            return self.modules[name]
        }
    }
}

/// Base class for services that perform PythonKit calls on a dedicated thread.
open class PythonService {
    public let pythonExecutor: PythonExecutor

    public init(executor: PythonExecutor) {
        self.pythonExecutor = executor
    }

    /// Run the given block on the Python thread and return its result asynchronously.
    public func callPython<T>(_ block: @escaping () -> T) async -> T {
        return await pythonExecutor.performAsync(block)
    }
}
