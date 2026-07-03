import Foundation

/// In-memory credential store for tests and previews.
public actor InMemoryCredentialStore: CredentialStore {
    private var credentials: [String: GitCredential] = [:]

    public init() {}

    public func save(_ credential: GitCredential, for connectionID: String) {
        credentials[connectionID] = credential
    }

    public func loadCredential(for connectionID: String) -> GitCredential? {
        credentials[connectionID]
    }

    public func deleteCredential(for connectionID: String) {
        credentials.removeValue(forKey: connectionID)
    }
}

/// In-memory connection store for tests and previews.
public actor InMemoryConnectionStore: ConnectionStore {
    private var storedConnections: [String: GitConnection] = [:]

    public init() {}

    public func save(_ connection: GitConnection) {
        storedConnections[connection.id] = connection
    }

    public func connections() -> [GitConnection] {
        Array(storedConnections.values)
    }

    public func connection(id: String) -> GitConnection? {
        storedConnections[id]
    }

    public func delete(id: String) {
        storedConnections.removeValue(forKey: id)
    }
}

/// JSON file-backed connection metadata store.
public actor FileConnectionStore: ConnectionStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL, filename: String = "git-pont-connections.json") {
        self.fileURL = directoryURL.appendingPathComponent(filename)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func save(_ connection: GitConnection) throws {
        var all = try loadAll()
        all[connection.id] = connection
        try saveAll(all)
    }

    public func connections() throws -> [GitConnection] {
        Array(try loadAll().values)
    }

    public func connection(id: String) throws -> GitConnection? {
        try loadAll()[id]
    }

    public func delete(id: String) throws {
        var all = try loadAll()
        all.removeValue(forKey: id)
        try saveAll(all)
    }

    private func loadAll() throws -> [String: GitConnection] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([String: GitConnection].self, from: data)
    }

    private func saveAll(_ connections: [String: GitConnection]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(connections)
        try data.write(to: fileURL, options: [.atomic])
    }
}
