//
//  AirPlayBrowser.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/21/25.
//

import AppKit
import Network
import Darwin

// 1) mDNS로 AirPlay 기기(Apple TV)를 찾는 브라우저
class AirPlayBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    /// Currently playing metadata from the selected Apple TV
    @Published var nowPlaying: String = ""
    @Published var hosts: [String] = ["Local"]
    var servicePorts: [String: Int] = [:]
    private let browser = NetServiceBrowser()

    override init() {
        super.init()
        browser.delegate = self
        // Ensure delegate callbacks fire on the main run loop
        browser.schedule(in: RunLoop.main, forMode: .common)
        print("[AirPlayBrowser] start searching for _airplay._tcp. in local.")
        browser.searchForServices(ofType: "_airplay._tcp.", inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("[AirPlayBrowser] didFind service:", service.name, "type:", service.type)
        // Update UI immediately with discovered service name
        DispatchQueue.main.async {
            if !self.hosts.contains(service.name) {
                self.hosts.append(service.name)
            }
        }
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netService(_ service: NetService, didResolveAddress addresses: [Data]) {
        print("[AirPlayBrowser] didResolve service:", service.name, "addresses:", addresses)
        for addr in addresses {
            addr.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
                let sockaddrPtr = pointer.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sockaddrPtr,
                               socklen_t(addr.count),
                               &hostBuffer,
                               socklen_t(hostBuffer.count),
                               nil, 0,
                               NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostBuffer)
                    DispatchQueue.main.async {
                        if !self.hosts.contains(ip) {
                            self.hosts.append(ip)
                            self.servicePorts[ip] = service.port
                            // Query now‑playing metadata for this host
                            self.fetchNowPlaying(host: ip, port: service.port)
                        }
                    }
                }
            }
        }
    }
    
    /// Fetch now‑playing info from AirPlay2 HTTP API endpoint
    func fetchNowPlaying(host: String, port: Int) {
        let urlString = "http://\(host):\(port)/playback-info?session-id=1"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AirPlayBrowser/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.nowPlaying = text
                }
            }
        }.resume()
    }
}
