import SwiftUI

/// Connection and quota scope stay together; content download routing has its
/// own existing control below Workspaces.
struct PikPakConnectionSelector: View {
    @ObservedObject var model: DownloaderModel
    @ObservedObject var monitor: PikPakTransferQuotaMonitor
    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { isPresented.toggle() } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(nsImage: FinderSymbolImage.template(named: "person.crop.circle.fill", style: .menu))
                            .foregroundStyle(FinderAppearance.accent)
                        Text(model.accountDisplayName ?? "Connect PikPak")
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(nsImage: FinderSymbolImage.template(named: "chevron.up.chevron.down", style: .menu))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(model.hasAccountSession ? FinderAppearance.accent : Color.orange).frame(width: 5, height: 5)
                        Text(model.isChangingAccount ? "Switching…" : model.hasAccountSession ? model.activeCredentialKind.loginTitle : "Sign-in required")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(FinderAppearance.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(FinderAppearance.accent.opacity(0.16)) }
                    .contentShape(RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).pointingHandCursor()
                .accessibilityLabel("PikPak account and login mode")
                .accessibilityValue("\(model.accountDisplayName ?? "Not connected"), \(model.activeCredentialKind.loginTitle)")
                .help("Switch PikPak account or choose normal login and token login")
                .popover(isPresented: $isPresented, arrowEdge: .top) { choices }
            if let error = model.accountSettingsError {
                Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(3).help(error)
            }
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PikPak connection").font(.headline)
                    Text("Choose how this workspace connects.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isChangingAccount { ProgressView().controlSize(.small) }
            }
            if !model.savedAccountGroups.isEmpty {
                Menu {
                    ForEach(model.savedAccountGroups) { group in
                        Button {
                            guard let connection = group.connection(model.activeCredentialKind) ?? group.connections.first else { return }
                            isPresented = false
                            model.selectPikPakConnection(connection.connectionKind, accountID: connection.id)
                        } label: {
                            if group.id == model.activeAccountGroup?.id {
                                Label(group.displayName, systemImage: "checkmark")
                            } else { Text(group.displayName) }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.accountDisplayName ?? "Choose account").fontWeight(.semibold)
                        if let accountID = model.activeSavedAccount?.accountIdentifier {
                            Text("ID: \(accountID)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(!model.canChangeAccount).help("Switch saved PikPak account")
            }
            VStack(spacing: 8) {
                ForEach(PikPakCredentialKind.allCases) { kind in connectionChoice(kind) }
            }
            if let reason = model.accountChangeBlockedReason {
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Both logins stay saved. The selected connection is used for account requests, downloads, previews and scans; Download Mode controls guest access.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Menu("Add Account…") {
                    Button("Normal login…") { addAccount(.desktopOAuth) }
                    Button("Personal access token…") { addAccount(.personalAccessToken) }
                }.fixedSize().disabled(!model.canChangeAccount)
                Spacer()
                FinderAccountSettingsLink(settings: model.finderSettings, pane: 2) {
                    Text("Account Settings…")
                }.simultaneousGesture(TapGesture().onEnded { isPresented = false })
            }.font(.caption)
        }.padding(16).frame(width: 354)
    }

    private func connectionChoice(_ kind: PikPakCredentialKind) -> some View {
        let saved = model.activeAccountGroup?.connection(kind)
        let selected = model.hasAccountSession && model.activeCredentialKind == kind
        let needsLogin = saved == nil || saved?.needsSignIn == true || (saved?.id == model.activeAccountID && !model.hasAccountSession)
        let counters = monitor.snapshot?.transfer.counters(for: kind)
        return Button {
            isPresented = false
            model.selectPikPakConnection(kind)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: FinderSymbolImage.template(named: kind.symbol, style: .menu))
                    .foregroundStyle(FinderAppearance.accent).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(kind.loginTitle).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(selected ? "Active" : needsLogin ? "Connect…" : "Saved")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(selected ? FinderAppearance.accent : .secondary)
                    }
                    Text(kind == .desktopOAuth ? "PikPak sign-in · full account quota" : "Personal access token · Connected Apps quota")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let quota = counters?.downstream {
                        Text("Downstream: \(pikpakTrafficBytes(quota.remaining)) of \(pikpakTrafficBytes(quota.total)) left")
                            .font(.caption).monospacedDigit().foregroundStyle(pikpakTrafficColor(quota))
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? FinderAppearance.accent.opacity(0.09) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? FinderAppearance.accent.opacity(0.5) : Color.primary.opacity(0.1)) }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).pointingHandCursor().disabled(!model.canChangeAccount)
            .accessibilityLabel(kind.loginTitle).accessibilityValue(selected ? "Active" : needsLogin ? "Connect" : "Saved")
            .accessibilityHint(needsLogin ? "Connect this login method and keep the existing connection" : "Switch to this saved connection")
    }

    private func addAccount(_ kind: PikPakCredentialKind) {
        isPresented = false
        model.beginAccountLogin(credentialKind: kind, fromSettings: false)
    }
}
