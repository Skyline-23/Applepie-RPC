//
//  PythonActor.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/23/25.
//

import Foundation
import OSLog
import PylibKit_Mac

typealias PythonExecutor = PylibKit_Mac.PythonExecutor

private enum AppLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "Applepie-RPC"
    static let logger = Logger(subsystem: subsystem, category: "app")
}

@inline(__always)
func debugLog(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    AppLogger.logger.info("\(message, privacy: .public)")
#if DEBUG
    Swift.print(message, terminator: terminator)
#endif
}

@inline(__always)
func errorLog(_ items: Any..., separator: String = " ") {
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    AppLogger.logger.error("\(message, privacy: .public)")
#if DEBUG
    Swift.print(message)
#endif
}

