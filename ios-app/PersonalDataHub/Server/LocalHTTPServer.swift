import Foundation
import Swifter

class LocalHTTPServer: ObservableObject {
    @Published var isRunning = false
    @Published var serverURL: String = ""

    private var server: HttpServer?
    let port: UInt16

    init(port: UInt16 = 8765) {
        self.port = port
    }

    func start(routes: Routes) {
        guard !isRunning else { return }

        let server = HttpServer()
        routes.register(on: server)

        do {
            try server.start(port, forceIPv4: true)
            self.server = server
            isRunning = true

            if let ip = getLocalIPAddress() {
                serverURL = "http://\(ip):\(port)"
            } else {
                serverURL = "http://localhost:\(port)"
            }
            print("[Server] Started on \(serverURL)")
        } catch {
            print("[Server] Failed to start: \(error)")
            isRunning = false
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        serverURL = ""
        print("[Server] Stopped")
    }

    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0, NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                }
            }
        }
        return address
    }
}
