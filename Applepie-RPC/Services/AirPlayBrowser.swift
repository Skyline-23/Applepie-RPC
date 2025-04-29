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
    @Published var hosts: [String] = [.localizable(.localhostName)]
    /// Resolved IPv4/IPv6 address for each service name
    var serviceIPs: [String: String] = [.localizable(.localhostName):"localhost"]
    private let browser = NetServiceBrowser()
    private var resolvingServices: [NetService] = []

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
        // Configure delegate and schedule before resolving
        service.delegate = self
        print("[AirPlayBrowser] Configuring service: \(service.name), delegate set: \(service.delegate != nil)")
        // Schedule resolution callbacks on multiple run loop modes
        service.schedule(in: RunLoop.main, forMode: .common)
        resolvingServices.append(service)
        service.resolve(withTimeout: 5)
        print("[AirPlayBrowser] Started resolve for \(service.name)")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        DispatchQueue.main.async {
            // Remove from hosts list
            self.hosts.removeAll { $0 == service.name }
            // Remove stored IP
            self.serviceIPs.removeValue(forKey: service.name)
        }
    }

    // Log failures to resolve service addresses
    func netService(_ service: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("[AirPlayBrowser] didNotResolveAddress for \(service.name), error: \(errorDict)")
        if let index = resolvingServices.firstIndex(where: { $0 === service }) {
            resolvingServices.remove(at: index)
        }
    }

    // Called when the service addresses have been resolved
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses, let addressData = addresses.first else {
            print("[AirPlayBrowser] No addresses to resolve for \(sender.name)")
            return
        }
        // Extract IPv4 address
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        addressData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            guard let sockaddrPtr = pointer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return }
            let result = getnameinfo(sockaddrPtr,
                                     socklen_t(addressData.count),
                                     &hostname,
                                     socklen_t(hostname.count),
                                     nil,
                                     0,
                                     NI_NUMERICHOST)
            guard result == 0 else {
                print("[AirPlayBrowser] getnameinfo failed with \(result) for \(sender.name)")
                return
            }
        }
        let ipAddress = String(cString: hostname)
        DispatchQueue.main.async {
            self.serviceIPs[sender.name] = ipAddress
            print("[AirPlayBrowser] Resolved IP for \(sender.name): \(ipAddress)")
        }
        // Release service after resolution
        if let index = resolvingServices.firstIndex(where: { $0 === sender }) {
            resolvingServices.remove(at: index)
        }
    }
}
