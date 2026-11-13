import ClipSyncCore
import Foundation
import Network

/// `ClipSync --self-test` exercises the same framing and envelope code over a
/// real loopback TCP connection. It is handy in CI and after packaging.
enum SelfTest {
    static func run() -> Int32 {
        let runner = SelfTestRunner()
        return runner.run()
    }
}

private final class SelfTestRunner {
    private let queue = DispatchQueue(label: "com.srihariphs.clipsync.selftest")
    private let done = DispatchSemaphore(value: 0)
    private let identity = PeerIdentity(id: "self-test", name: "Self Test")

    private var listener: NWListener?
    private var client: NWConnection?
    private var server: NWConnection?
    private var finished = false
    private var exitCode: Int32 = 1

    func run() -> Int32 {
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.connect()
                case .failed(let error):
                    self.fail("listener failed: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        } catch {
            print("self-test failed: could not start listener: \(error)")
            return 1
        }

        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.fail("timed out")
        }

        done.wait()
        return exitCode
    }

    private func connect() {
        guard let port = listener?.port else {
            fail("listener did not get a port")
            return
        }
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.client = client
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendTestClip()
            case .failed(let error):
                self.fail("client failed: \(error)")
            default:
                break
            }
        }
        client.start(queue: queue)
    }

    private func sendTestClip() {
        let clip = Clip(
            kind: .text,
            text: "loopback self-test",
            originID: identity.id,
            originName: identity.name
        )
        let envelope = Envelope.clip(clip, sender: identity, codeHash: "")

        do {
            let frame = try WireCoding.framed(envelope)
            client?.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error { self?.fail("send failed: \(error)") }
            })
            receiveOnClient()
        } catch {
            fail("encoding failed: \(error)")
        }
    }

    private func receiveOnClient() {
        var decoder = FrameDecoder()

        func receiveMore() {
            client?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }

                if let data, !data.isEmpty {
                    decoder.append(data)
                    if let payload = try? decoder.nextPayload() {
                        guard let envelope = try? WireCoding.decode(Envelope.self, from: payload),
                              envelope.clip?.text == "loopback self-test"
                        else {
                            self.fail("unexpected echo payload")
                            return
                        }
                        self.succeed()
                        return
                    }
                }

                if let error {
                    self.fail("receive failed: \(error)")
                    return
                }
                if isComplete {
                    self.fail("connection closed before echo")
                    return
                }
                receiveMore()
            }
        }
        receiveMore()
    }

    private func serve(_ connection: NWConnection) {
        server = connection
        connection.start(queue: queue)
        var decoder = FrameDecoder()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }

                if let data, !data.isEmpty {
                    decoder.append(data)
                    if let payload = try? decoder.nextPayload(), let frame = try? FrameCodec.encode(payload) {
                        connection.send(content: frame, completion: .contentProcessed { _ in })
                        return
                    }
                }

                if error != nil || isComplete {
                    self.fail("server closed before receiving a clip")
                    return
                }
                receiveMore()
            }
        }
        receiveMore()
    }

    private func succeed() {
        finish(code: 0, message: "self-test passed: loopback framing and envelope round-trip work")
    }

    private func fail(_ message: String) {
        finish(code: 1, message: "self-test failed: \(message)")
    }

    private func finish(code: Int32, message: String) {
        guard !finished else { return }
        finished = true
        exitCode = code
        print(message)
        client?.cancel()
        server?.cancel()
        listener?.cancel()
        done.signal()
    }
}
