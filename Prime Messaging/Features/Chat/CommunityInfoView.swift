import SwiftUI

struct CommunityInfoView: View {
    @Binding var chat: Chat
    var onRequestSearch: (() -> Void)? = nil
    var onGroupDeleted: (() -> Void)? = nil
    var onGroupLeft: (() -> Void)? = nil

    var body: some View {
        GroupInfoView(
            chat: $chat,
            onRequestSearch: onRequestSearch,
            onGroupDeleted: onGroupDeleted,
            onGroupLeft: onGroupLeft,
            forcedCommunityKind: .community
        )
    }
}
