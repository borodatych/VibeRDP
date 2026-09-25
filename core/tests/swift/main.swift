// Swift imports the VibeRDPCore framework module, as the app does
// A refused connection must come back through C callbacks as native Swift enums and values

import Darwin
import Dispatch
import VibeRDPCore

final class Observer {
    let finished = DispatchSemaphore(value: 0)
    var states: [VRCSessionState] = []
    var errorCode: UInt32 = 0
}

// A loopback port that was free a moment ago: connecting to it is refused
func unusedPort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0, "socket failed")
    defer { close(fd) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            bind(fd, generic, length) == 0 && getsockname(fd, generic, &length) == 0
        }
    }
    precondition(bound, "bind failed")
    return UInt16(bigEndian: address.sin_port)
}

func observer(from userData: UnsafeMutableRawPointer?) -> Observer {
    Unmanaged<Observer>.fromOpaque(userData!).takeUnretainedValue()
}

let watched = Observer()
var callbacks = VRCCallbacks(
    stateChanged: { userData, state in
        let target = observer(from: userData)
        target.states.append(state)
        if state == .disconnected {
            target.finished.signal()
        }
    },
    error: { userData, _, code, _, _ in
        observer(from: userData).errorCode = code
    },
    verifyCertificate: nil,
    frameResized: nil,
    frameUpdated: nil,
    pointerChanged: nil)

guard let session = VRCSessionCreate(&callbacks, Unmanaged.passUnretained(watched).toOpaque()) else {
    fatalError("VRCSessionCreate returned nil")
}

let result: VRCResult = "127.0.0.1".withCString { host in
    var params = VRCConnectionParams(
        host: host, port: unusedPort(), width: 0, height: 0, username: nil, domain: nil, password: nil)
    return VRCSessionConnect(session, &params)
}
precondition(result == .OK, "VRCSessionConnect returned \(result)")
precondition(watched.finished.wait(timeout: .now() + 10) == .success, "no Disconnected within 10 s")
VRCSessionDestroy(session)

precondition(watched.states == [.connecting, .disconnected], "unexpected states \(watched.states)")
precondition(watched.errorCode != 0, "a refused connection must report an engine error")
// Imported C enums print without case names, hence the raw values
print("OK: states \(watched.states.map(\.rawValue)), engine error 0x\(String(watched.errorCode, radix: 16))")
