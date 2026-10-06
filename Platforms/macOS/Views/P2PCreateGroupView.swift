import SwiftUI

struct P2PCreateGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var p2pService = P2PService.shared
    @State private var groupName = ""
    @State private var selectedFriends: Set<UUID> = []

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("创建群组")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
            }

            TextField("群组名称", text: $groupName)
                .textFieldStyle(.roundedBorder)

            if p2pService.friends.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("暂无好友，请先添加好友")
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                List(p2pService.friends) { friend in
                    HStack {
                        Image(systemName: selectedFriends.contains(friend.id)
                            ? "checkmark.circle.fill"
                            : "circle")
                            .foregroundColor(.accentColor)

                        Text(friend.nickname)
                            .font(.body)

                        Spacer()

                        if p2pService.connectionStatus[friend.id] == .online {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedFriends.contains(friend.id) {
                            selectedFriends.remove(friend.id)
                        } else {
                            selectedFriends.insert(friend.id)
                        }
                    }
                }
                .listStyle(.plain)
            }

            Button {
                p2pService.createGroup(name: groupName, memberIDs: Array(selectedFriends))
                dismiss()
            } label: {
                Text("创建群组")
            }
            .buttonStyle(.borderedProminent)
            .disabled(groupName.isEmpty || selectedFriends.isEmpty)
        }
        .padding()
        .frame(width: 400, height: 450)
    }
}
