//
//  SentryBootstrapService.swift
//  Applepie-RPC
//

import Foundation
import Sentry

final class SentryBootstrapService {
    func startIfConfigured(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        let rawDSN = info["SentryDSN"] as? String
        let dsn = rawDSN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if dsn.isEmpty || dsn.contains("SENTRY_DSN") || dsn.contains("$(") {
            debugLog("[Sentry] DSN not configured; skipping Sentry init")
            return
        }

        let environmentFromInfo = (info["SentryEnvironment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let bundleID = bundle.bundleIdentifier ?? "Applepie-RPC"

        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = version
            if let env = environmentFromInfo, !env.isEmpty {
                options.environment = env
            } else {
                options.environment = "production"
            }
            options.enableCrashHandler = true
            options.attachStacktrace = true
        }

        SentrySDK.configureScope { scope in
            scope.setTag(value: bundleID, key: "bundle_id")
            scope.setTag(value: version, key: "app_version")
        }
    }
}
