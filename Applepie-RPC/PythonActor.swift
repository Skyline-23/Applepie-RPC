//
//  PythonActor.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/23/25.
//

import Foundation
import PylibKit_Mac

// Re-export PylibKit types for convenience within the app module.
typealias PythonExecutor = PylibKit_Mac.PythonExecutor

@inline(__always)
func debugLog(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(message, terminator: terminator)
#endif
}
