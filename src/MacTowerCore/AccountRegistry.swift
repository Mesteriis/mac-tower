import Foundation

public actor AccountRegistry {
    private let storage: PrivateFileStore
    private var accounts: [AccountRegistration]

    public init(storage: PrivateFileStore) throws {
        self.storage = storage
        if let data = try storage.read(named: "accounts.json") {
            let decoded = try JSONDecoder().decode([AccountRegistration].self, from: data)
            for account in decoded { try account.validate() }
            accounts = decoded
        } else {
            accounts = []
        }
    }

    public func all() -> [AccountRegistration] {
        accounts.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func upsert(_ account: AccountRegistration) throws {
        try account.validate()
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        try persist()
    }

    public func remove(id: AccountID) throws -> AccountRegistration? {
        let removed = accounts.first { $0.id == id }
        accounts.removeAll { $0.id == id }
        try persist()
        return removed
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try storage.write(try encoder.encode(accounts), named: "accounts.json")
    }
}
