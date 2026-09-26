import Foundation

/// Why the windows of Windows do or do not show, in the words of the user: roadmap 8.2
/// The client sees only what the channel says, so a helper that is missing, blocked by policy or not started
/// looks the same; the advice names every one of them rather than guessing
enum SeamDiagnosis: Equatable {
    /// The link is ready and the helper reports windows
    case working(agent: String)
    /// The channel is open and the hello is on its way
    case waiting
    /// No helper answered: not installed, blocked, or not started in this session
    case noHelper
    case otherVersion(UInt64)
    /// The helper answered and then stopped
    case lost
    /// A helper that answers but does not report windows: a build older than the window stages
    case noWindows(agent: String)

    static func of(_ state: SeamLink.State) -> SeamDiagnosis {
        switch state {
        case .ready(let agent, let capabilities):
            capabilities.contains("windows") ? .working(agent: agent) : .noWindows(agent: agent)
        case .greeting:
            .waiting
        case .closed, .silent:
            .noHelper
        case .incompatible(let version):
            .otherVersion(version)
        case .lost:
            .lost
        }
    }

    /// A line of the explanation: the text and its values
    struct Line: Equatable {
        let key: TextKey
        var values: [String: String] = [:]
    }

    var title: Line {
        switch self {
        case .working: Line(key: .seamDiagnosisWorkingTitle)
        case .waiting: Line(key: .seamDiagnosisWaitingTitle)
        case .noHelper: Line(key: .seamDiagnosisNoHelperTitle)
        case .otherVersion: Line(key: .seamDiagnosisOtherVersionTitle)
        case .lost: Line(key: .seamDiagnosisLostTitle)
        case .noWindows: Line(key: .seamDiagnosisNoWindowsTitle)
        }
    }

    /// What happened and what to do, a line each; a refused RemoteApp adds its own line in front
    func advice(remoteAppRefused: Bool) -> [Line] {
        var lines = remoteAppRefused ? [Line(key: .seamDiagnosisRemoteAppRefused)] : []
        switch self {
        case .working(let agent):
            lines.append(Line(key: .seamDiagnosisWorking, values: ["agent": agent]))
        case .waiting:
            lines.append(Line(key: .seamDiagnosisWaiting))
        case .noHelper:
            lines += [
                Line(key: .seamDiagnosisNotInstalled), Line(key: .seamDiagnosisAppLocker),
                Line(key: .seamDiagnosisNotStarted),
            ]
        case .otherVersion(let version):
            lines.append(
                Line(key: .seamDiagnosisOtherVersion, values: ["theirs": String(version), "ours": String(SeamLink.version)]))
        case .lost:
            lines.append(Line(key: .seamDiagnosisLost))
        case .noWindows(let agent):
            lines.append(Line(key: .seamDiagnosisNoWindows, values: ["agent": agent]))
        }
        return lines
    }
}
