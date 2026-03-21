import Foundation
import Network

class BonjourAdvertiser: ObservableObject {
    @Published var isAdvertising = false

    private var listener: NWListener?
    private let serviceType = "_personaldatahub._tcp"
    private let httpPort: UInt16

    init(httpPort: UInt16 = 8765) {
        self.httpPort = httpPort
    }

    func start() {
        guard !isAdvertising else { return }

        do {
            // Use a random available port for the NWListener (not the HTTP port which Swifter owns)
            let params = NWParameters.tcp
            listener = try NWListener(using: params)
        } catch {
            print("[Bonjour] Failed to create listener: \(error)")
            return
        }

        // Advertise with TXT record containing the actual HTTP port
        let txtData = ["port": "\(httpPort)"]
        listener?.service = NWListener.Service(
            name: "PersonalDataHub",
            type: serviceType,
            txtRecord: NWTXTRecord(txtData)
        )

        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isAdvertising = true
                    if let port = self?.listener?.port?.rawValue {
                        print("[Bonjour] Advertising \(self?.serviceType ?? "") (listener port: \(port), HTTP port: \(self?.httpPort ?? 0))")
                    }
                case .failed(let error):
                    self?.isAdvertising = false
                    print("[Bonjour] Failed: \(error)")
                case .cancelled:
                    self?.isAdvertising = false
                default:
                    break
                }
            }
        }

        // Accept and immediately close — this listener exists only for Bonjour advertisement
        listener?.newConnectionHandler = { connection in
            connection.cancel()
        }

        listener?.start(queue: .global(qos: .utility))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isAdvertising = false
        }
    }
}
