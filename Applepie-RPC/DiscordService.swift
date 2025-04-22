//
//  DiscordService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/21/25.
//

import PythonKit
import Foundation

class DiscordService {
    private let rpc: PythonObject

    init(clientID: String) {
        // 1) Embedded libpython 로드 (이미 AppDelegate에서 했으면 생략 가능)
        let libPath = Bundle.main.privateFrameworksURL!
            .appendingPathComponent("Python.framework")
            .appendingPathComponent("Versions/3.12")
            .appendingPathComponent("Python").path
        PythonLibrary.useLibrary(at: libPath)

        // 2) pypresence 모듈 로드 & Presence 객체 생성
        let pypres = Python.import("pypresence")
        let Presence = pypres.Presence
        rpc = Presence(clientID)

        // 3) Discord 데스크탑과 연결
        rpc.connect()
    }

    func setActivity(details: String, state: String, largeImage: String? = nil) {
        // PythonKit에서는 키워드 인자를 Swift 메서드처럼 넘길 수 있습니다.
        if let img = largeImage {
            rpc.update(details: details, state: state, large_image: img)
        } else {
            rpc.update(details: details, state: state)
        }
    }

    func clearActivity() {
        rpc.clear()
    }
}
