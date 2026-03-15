import Foundation

final class AppState: ObservableObject {
    @Published var selectedMode: ChatMode = .online
    @Published var selectedChat: Chat?
    @Published var currentUser: User = .mockCurrentUser
    @Published var hasCompletedOnboarding = true
}
