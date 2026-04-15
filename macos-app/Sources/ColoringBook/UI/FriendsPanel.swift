import SwiftUI

/// Replaces the old ConnectionStatusView as the top-of-side-panel block.
/// Shows who you are + your friends + pending requests + "add friend". Click
/// a friend to open a DM room with them.
struct FriendsPanel: View {
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var session: SessionModel
    @State private var showAddFriend = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            modeStatusRow
            if !auth.pendingRequests.isEmpty {
                pendingSection
            }
            friendsSection
        }
        .sheet(isPresented: $showAddFriend) {
            AddFriendSheet()
        }
    }

    @ViewBuilder private var headerRow: some View {
        if case .authenticated(let user, _) = auth.state {
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(user.displayName).font(.subheadline).fontWeight(.semibold)
                    Text("@\(user.username)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Log out", role: .destructive) {
                        Task { await auth.logout() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var modeStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isInCanvasMode
                  ? "pencil.tip.crop.circle.fill" : "cursorarrow")
                .foregroundStyle(session.isInCanvasMode ? Color.accentColor : .secondary)
            Text(session.isInCanvasMode ? "Canvas mode" : "Pointer mode")
                .font(.caption).fontWeight(.medium)
            Spacer()
            Text("\(Int(session.zoom * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Requests").font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ForEach(auth.pendingRequests) { req in
                PendingRequestRow(req: req)
            }
        }
        .padding(.top, 4)
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SketchbookRow()
            HStack {
                Text("Friends").font(.headline)
                Spacer()
                Button {
                    showAddFriend = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("Add a friend")
            }
            if auth.friends.isEmpty {
                Text("No friends yet — click + to send a request.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(auth.friends) { friend in
                    FriendRow(friend: friend)
                }
            }
        }
    }
}

private struct SketchbookRow: View {
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var session: SessionModel

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text("My sketchbook").font(.subheadline).fontWeight(.medium)
                    Text("Private — just for you")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if session.roomId == soloRoomId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(session.roomId == soloRoomId
                          ? Color.accentColor.opacity(0.12)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var soloRoomId: String {
        guard case .authenticated(let me, _) = auth.state else { return "" }
        return "solo:\(me.id)"
    }

    private func open() {
        guard case .authenticated(let me, _) = auth.state else { return }
        session.switchRoom(id: "solo:\(me.id)", displayName: "My sketchbook")
    }
}

private struct PendingRequestRow: View {
    @EnvironmentObject var auth: AuthModel
    let req: PendingRequestDTO

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(req.displayName).font(.caption).fontWeight(.medium)
                Text("@\(req.username) wants to add you")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await auth.accept(req.requesterId) }
            } label: {
                Image(systemName: "checkmark").foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help("Accept")
            Button {
                Task { await auth.decline(req.requesterId) }
            } label: {
                Image(systemName: "xmark").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Decline")
        }
    }
}

private struct FriendRow: View {
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var session: SessionModel
    let friend: FriendDTO

    var body: some View {
        Button(action: openDM) {
            HStack(spacing: 8) {
                Circle()
                    .fill(friend.online ? Color.green : Color.gray.opacity(0.45))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(friend.displayName).font(.subheadline)
                    Text("@\(friend.username)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if session.roomId == dmRoomId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(session.roomId == dmRoomId
                          ? Color.accentColor.opacity(0.12)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var dmRoomId: String {
        guard case .authenticated(let me, _) = auth.state else { return "" }
        let ids = [me.id, friend.id].sorted()
        return "dm:\(ids[0]):\(ids[1])"
    }

    private func openDM() {
        guard case .authenticated(let me, _) = auth.state else { return }
        let ids = [me.id, friend.id].sorted()
        session.switchRoom(
            id: "dm:\(ids[0]):\(ids[1])",
            displayName: friend.displayName
        )
    }
}

private struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthModel

    @State private var username = ""
    @State private var resultMessage: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a friend").font(.headline)
            Text("Enter a username — they'll get a pending request to accept.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            if let msg = resultMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Send request") {
                    busy = true
                    Task {
                        resultMessage = await auth.sendFriendRequest(username: username)
                        busy = false
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(busy || username.isEmpty)
            }
        }
        .padding()
        .frame(width: 340)
    }
}
