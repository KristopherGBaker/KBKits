import Foundation
import KBLLM

/// `GET {baseURL}/v1/models` on Anthropic (the same server root `AnthropicModel` takes), following `has_more` and `last_id`
/// page by page, newest first as the API lists them.
public struct AnthropicModelList: ModelListing {
    private let baseURL: String
    private let credentialKey: String
    private let transport: any HTTPTransport
    private let credentials: any CredentialStore
    /// The most pages read, so a server that always says `has_more` cannot loop forever.
    private static let maximumPages = 20

    public init(
        baseURL: String = "https://api.anthropic.com", credentialKey: String, transport: any HTTPTransport,
        credentials: any CredentialStore
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.credentialKey = credentialKey
        self.transport = transport
        self.credentials = credentials
    }

    public func listModels() async throws -> [ListedModel] {
        let secret = try await credentials.resolvedSecret(forKey: credentialKey)
        let headers = ["x-api-key": secret, "anthropic-version": "2023-06-01", "accept": "application/json"]
        var models: [ListedModel] = []
        var after: String?
        for _ in 0..<Self.maximumPages {
            var url = baseURL + "/v1/models?limit=1000"
            if let after { url += "&after_id=" + (after.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? after) }
            guard URL(string: url) != nil else {
                throw KBLLMError.invalidRequest(field: "baseURL", reason: "malformed base URL: \(baseURL)")
            }
            let data = try ListedModel.checked(await transport.send(HTTPRequestSpec(method: .get, url: url, headers: headers)))
            models += try ListedModel.parseList(data)
            let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard page?["has_more"] as? Bool == true, let last = page?["last_id"] as? String, !last.isEmpty else { break }
            after = last
        }
        return models
    }
}
