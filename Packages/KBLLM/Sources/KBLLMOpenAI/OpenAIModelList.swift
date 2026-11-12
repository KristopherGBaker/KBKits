import Foundation
import KBLLM

/// `GET {baseURL}/models` on OpenAI or an OpenAI-compatible server (the same base URL `OpenAIModel` takes, version segment
/// included), with the same Bearer key and extra headers a request carries. An empty key sends no Authorization header, as
/// `OpenAIModel` does. `url` replaces the composed endpoint for a server whose catalog lives elsewhere.
public struct OpenAIModelList: ModelListing {
    private let endpoint: String
    private let credentialKey: String
    private let extraHeaders: [String: String]
    private let transport: any HTTPTransport
    private let credentials: any CredentialStore

    public init(
        baseURL: String = "https://api.openai.com/v1",
        url: String? = nil,
        credentialKey: String,
        extraHeaders: [String: String] = [:],
        transport: any HTTPTransport,
        credentials: any CredentialStore
    ) {
        endpoint = url ?? (baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL) + "/models"
        self.credentialKey = credentialKey
        self.extraHeaders = extraHeaders
        self.transport = transport
        self.credentials = credentials
    }

    public func listModels() async throws -> [ListedModel] {
        guard URL(string: endpoint) != nil else {
            throw KBLLMError.invalidRequest(field: "baseURL", reason: "malformed models URL: \(endpoint)")
        }
        let secret = try await credentials.resolvedSecret(forKey: credentialKey)
        var headers = OpenAIModel.requestHeaders(secret: secret, extraHeaders: extraHeaders)
        headers["content-type"] = nil
        if !headers.keys.contains(where: { $0.lowercased() == "accept" }) { headers["accept"] = "application/json" }
        let response = try await transport.send(HTTPRequestSpec(method: .get, url: endpoint, headers: headers))
        return try ListedModel.parseList(ListedModel.checked(response))
    }
}
