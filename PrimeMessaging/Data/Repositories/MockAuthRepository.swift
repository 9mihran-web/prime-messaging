import Foundation

struct MockAuthRepository: AuthRepository {
    func currentUser() async throws -> User {
        .mockCurrentUser
    }
}
