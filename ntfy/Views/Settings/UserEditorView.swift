//
//  UserEditorView.swift
//  ntfy
//
//  Created by Alek Michelson on 4/10/26.
//

import SwiftUI

struct UserEditorView: View {
    @EnvironmentObject private var store: Store
    
    let selectedUser: User?
    /// The selected user's saved credentials, used to keep the secret when its field is left blank.
    let storedCredentials: UserCredentials?
    let onSave: (String, UserCredentials) -> Void
    let onDelete: (User) -> Void
    let onCancel: () -> Void
    
    @State private var baseUrl: String
    @State private var username: String
    @State private var password: String
    @State private var token: String
    @State private var authMethod: AuthMethod
    
    init(
        selectedUser: User?,
        storedCredentials: UserCredentials?,
        onSave: @escaping (String, UserCredentials) -> Void,
        onDelete: @escaping (User) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.selectedUser = selectedUser
        self.storedCredentials = storedCredentials
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _baseUrl = State(initialValue: selectedUser?.baseUrl ?? "")
        _username = State(initialValue: selectedUser?.username ?? "")
        _password = State(initialValue: "")
        _token = State(initialValue: "")
        _authMethod = State(initialValue: storedCredentials?.isToken == true ? .token : .password)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sign in with", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section(footer: footer) {
                    if isNewUser {
                        TextField("Service URL, e.g. https://ntfy.home.io", text: $baseUrl)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                    }
                    switch authMethod {
                    case .password:
                        TextField("Username", text: $username)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                        SecureField("Password", text: $password)
                    case .token:
                        SecureField("Access token (tk_…)", text: $token)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                    }
                }
            }
            .navigationTitle(isNewUser ? "Add user" : "Edit user")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isNewUser {
                        Button("Cancel") {
                            onCancel()
                        }
                    } else {
                        Menu {
                            Button("Cancel") {
                                onCancel()
                            }
                            Button(role: .destructive) {
                                deleteAction()
                            } label: {
                                Text("Delete")
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: saveAction) {
                        Text("Save")
                    }
                    .disabled(!isValid())
                }
            }
        }
    }
    
    private var isNewUser: Bool {
        selectedUser == nil
    }

    /// Whether a blank secret field may keep the stored secret: only when editing a user that
    /// already signs in with the selected method.
    private var canKeepStoredSecret: Bool {
        guard let storedCredentials else { return false }
        return storedCredentials.isToken == (authMethod == .token)
    }

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var footer: Text {
        switch authMethod {
        case .password:
            return isNewUser
            ? Text("You can add a user here. All topics for the given server will use this user.")
            : Text("Edit the username or password for \(shortUrl(url: baseUrl)) here. This user is used for all topics of this server.\(canKeepStoredSecret ? " Leave the password blank to leave it unchanged." : "")")
        case .token:
            return Text("Create an access token in the ntfy web app under Account, or with `ntfy token add`. It is used for all topics of \(isNewUser ? "the given server" : shortUrl(url: baseUrl)).\(canKeepStoredSecret ? " Leave the token blank to leave it unchanged." : "")")
        }
    }
    
    private func saveAction() {
        switch authMethod {
        case .password:
            let finalPassword: String
            if canKeepStoredSecret, password.isEmpty, case .basic(_, let storedPassword) = storedCredentials {
                finalPassword = storedPassword
            } else {
                finalPassword = password
            }
            onSave(baseUrl, .basic(username: username, password: finalPassword))
        case .token:
            let finalToken: String
            if canKeepStoredSecret, trimmedToken.isEmpty, case .token(let storedToken) = storedCredentials {
                finalToken = storedToken
            } else {
                finalToken = trimmedToken
            }
            onSave(baseUrl, .token(finalToken))
        }
    }
    
    private func deleteAction() {
        guard let selectedUser = selectedUser else { return }
        onDelete(selectedUser)
    }
    
    private func isValid() -> Bool {
        if isNewUser {
            if baseUrl.range(of: "^https?://.+", options: .regularExpression, range: nil, locale: nil) == nil {
                return false
            } else if store.getUser(baseUrl: baseUrl) != nil {
                return false
            }
        }
        switch authMethod {
        case .password:
            return !username.isEmpty && (canKeepStoredSecret || !password.isEmpty)
        case .token:
            return canKeepStoredSecret || !trimmedToken.isEmpty
        }
    }
}

private enum AuthMethod: String, CaseIterable, Identifiable {
    case password
    case token

    var id: Self { self }

    var title: String {
        switch self {
        case .password: return "Password"
        case .token: return "Access token"
        }
    }
}
