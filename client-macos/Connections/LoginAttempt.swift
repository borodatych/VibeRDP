import Foundation

/// One try to sign in with a profile, and what becomes of its password once the server lets the user in
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

    /// The first try of a profile: the password typed in the editor, else the saved one, else none
    static func first(for profile: ConnectionProfile, typed: String, saved: String?) -> LoginAttempt {
        let password: String? = typed.isEmpty ? saved : typed
        return LoginAttempt(
            profileID: profile.id, username: profile.username, password: password, typedByUser: !typed.isEmpty,
            remember: profile.remembersPassword)
    }

    /// The user answered a question about credentials, during a connection or after a wrong password
    mutating func answered(username: String, password: String, remember: Bool) {
        self.username = username
        self.password = password
        typedByUser = true
        self.remember = remember
    }

    /// What to save once connected: a password the user typed and wants remembered
    var passwordToSave: String? {
        guard remember, typedByUser, let password, !password.isEmpty else { return nil }
        return password
    }
}
