import Foundation

/// One row in a fetched `/v1/models` catalog. `displayName` is Anthropic-only;
/// OpenAI's listing only carries the wire id.
struct ModelCatalogEntry: Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String?
}

/// Hits the provider's own `/v1/models` endpoint and returns the wire ids.
/// Cached in-memory per `Provider.id` so reopening the editor doesn't burn a
/// round trip on every keystroke. Use `force: true` from the Refresh button.
///
/// Auth: send both `x-api-key` and `Authorization: Bearer` so proxy or
/// gateway setups don't depend on which header the endpoint actually checks.
actor ModelCatalogService {
    static let shared = ModelCatalogService()

    private var cache: [UUID: [ModelCatalogEntry]] = [:]

    func cached(for providerId: UUID) -> [ModelCatalogEntry]? {
        cache[providerId]
    }

    func fetch(for provider: Provider,
               force: Bool = false) async throws -> [ModelCatalogEntry] {
        if !force, let hit = cache[provider.id] { return hit }
        let entries: [ModelCatalogEntry]
        switch provider.vendor {
        case .claude: entries = try await fetchAnthropic(provider)
        case .codex:  entries = try await fetchOpenAI(provider)
        }
        cache[provider.id] = entries
        return entries
    }

    func clear(_ providerId: UUID) {
        cache[providerId] = nil
    }

    // MARK: - Vendor fetchers

    private func fetchAnthropic(_ p: Provider) async throws -> [ModelCatalogEntry] {
        let url = try modelsURL(base: p.baseURL,
                                fallback: "https://api.anthropic.com")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyAuth(p, to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validate(resp, data)
        struct Body: Decodable {
            struct Item: Decodable { var id: String; var display_name: String? }
            var data: [Item]
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return body.data.map {
            ModelCatalogEntry(id: $0.id, displayName: $0.display_name)
        }
    }

    private func fetchOpenAI(_ p: Provider) async throws -> [ModelCatalogEntry] {
        let url = try modelsURL(base: p.baseURL,
                                fallback: "https://api.openai.com")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuth(p, to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validate(resp, data)
        struct Body: Decodable {
            struct Item: Decodable { var id: String }
            var data: [Item]
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return body.data.map {
            ModelCatalogEntry(id: $0.id, displayName: nil)
        }
    }

    // MARK: - Helpers

    private func applyAuth(_ p: Provider, to req: inout URLRequest) {
        guard !p.authToken.isEmpty else { return }
        req.setValue(p.authToken, forHTTPHeaderField: "x-api-key")
        req.setValue("Bearer " + p.authToken, forHTTPHeaderField: "Authorization")
    }

    /// Resolves `${base}/v1/models`, accepting bases with or without a
    /// trailing slash, with `/v1` already in the path, or already pointing at
    /// `/models`.
    private func modelsURL(base: String, fallback: String) throws -> URL {
        let raw = base.isEmpty ? fallback : base
        var trimmed = raw
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let path: String
        if trimmed.hasSuffix("/models") {
            path = trimmed
        } else if trimmed.hasSuffix("/v1") {
            path = trimmed + "/models"
        } else {
            path = trimmed + "/v1/models"
        }
        guard let url = URL(string: path) else {
            throw NSError(
                domain: "ModelCatalog", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(path)"])
        }
        return url
    }

    private func validate(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let snippet = String(body.prefix(200))
            throw NSError(
                domain: "ModelCatalog", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                            "HTTP \(http.statusCode) — \(snippet)"])
        }
    }
}
