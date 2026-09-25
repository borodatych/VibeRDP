import Foundation

/// One try to sign in with a profile, and what becomes of its passwords once the server lets the user in
/// A password goes to the Keychain only after the server accepted it: a wrong one is never saved
struct LoginAttempt: Equatable {
    let profileID: UUID
    /// DOMAIN\user or user@domain; empty lets the engine ask when the server needs a name
    var username: String
    /// nil lets the engine ask when the server needs a password
    var password: String?
    /// The user typed the password for this try, rather than the Keychain giving it
    var typedByUser: Bool
    var remember: Bool
    /// The gateway's own credentials; unused when the gateway takes those of the computer
    var gatewayUsername: String
    var gatewayPassword: String?
    var gatewayTypedByUser: Bool

    /// The first try of a profile: the password typed in the editor, else the saved one, else none
    static func first(
        for profile: ConnectionProfile, typed: String, saved: String?, savedGateway: String?
    ) -> LoginAttempt {
        let password: String? = typed.isEmpty ? saved : typed
        return LoginAttempt(
            profileID: profile.id, username: profile.username, password: password, typedByUser: !typed.isEmpty,
            remember: profile.remembersPassword, gatewayUsername: profile.gatewayUsername,
            gatewayPassword: savedGateway, gatewayTypedByUser: false)
    }

    /// The user answered a question about the computer's credentials
    mutating func answered(username: String, password: String, remember: Bool) {
        self.username = username
        self.password = password
        typedByUser = true
        self.remember = remember
    }

    /// The user answered a question about the gateway's own credentials
    mutating func answeredGateway(username: String, password: String, remember: Bool) {
        gatewayUsername = username
        gatewayPassword = password
        gatewayTypedByUser = true
        self.remember = remember
    }

    /// What to save once connected: a password the user typed and wants remembered
    var passwordToSave: String? {
        Self.worthSaving(password, typed: typedByUser, remember: remember)
    }

    var gatewayPasswordToSave: String? {
        Self.worthSaving(gatewayPassword, typed: gatewayTypedByUser, remember: remember)
    }

    private static func worthSaving(_ password: String?, typed: Bool, remember: Bool) -> String? {
        guard remember, typed, let password, !password.isEmpty else { return nil }
        return password
    }
}
