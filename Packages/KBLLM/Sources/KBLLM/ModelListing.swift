import Foundation

/// One model a provider's list endpoint names: its API id, and the display name and creation time when the provider gives
/// them.
public struct ListedModel: Sendable, Hashable {
    public var id: String
    public var displayName: String?
    public var created: Date?

    public init(id: String, displayName: String? = nil, created: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.created = created
    }
}

/// Lists the models a provider offers, apart from `LanguageModel` (which stays one request in, events out): a settings
/// screen asks for the list, a turn never does. Each adapter module ships its own (`OpenAIModelList`, `AnthropicModelList`)
/// over the same `HTTPTransport` and `CredentialStore` seams, so a test replays a recorded list through a fake transport.
public protocol ModelListing: Sendable {
    /// The provider's models, in the order it lists them. Throws `.missingCredential` when the key cannot be read, the
    /// transport's `.httpStatus` for a rejected request, and `.decoding` for a body that is not a model list.
    func listModels() async throws -> [ListedModel]
}

public extension ListedModel {
    /// The models in one list response. Two shapes are read: an object whose `data` is the list (OpenAI, Anthropic and the
    /// OpenAI-compatible servers), and a bare array (a catalog such as GitHub Models'). Each entry needs an `id`; its
    /// `display_name` or `name` is the display name, and `created` (Unix seconds) or `created_at` (ISO 8601) its time. An
    /// entry without an id is skipped.
    static func parseList(_ data: Data) throws -> [ListedModel] {
        let object = try? JSONSerialization.jsonObject(with: data)
        let entries: [Any]
        if let array = object as? [Any] {
            entries = array
        } else if let list = (object as? [String: Any])?["data"] as? [Any] {
            entries = list
        } else {
            throw KBLLMError.decoding(
                expected: "a model list ({\"data\": [...]} or [...])",
                fragment: String(decoding: data.prefix(200), as: UTF8.self)
            )
        }
        return entries.compactMap { entry in
            guard let fields = entry as? [String: Any], let id = fields["id"] as? String, !id.isEmpty else { return nil }
            let name = (fields["display_name"] as? String) ?? (fields["name"] as? String)
            var created: Date?
            if let seconds = fields["created"] as? Double {
                created = Date(timeIntervalSince1970: seconds)
            } else if let text = fields["created_at"] as? String {
                created = ISO8601DateFormatter().date(from: text)
            }
            return ListedModel(id: id, displayName: name.flatMap { $0.isEmpty ? nil : $0 }, created: created)
        }
    }

    /// The transport's response checked: a status outside 2xx is `.httpStatus` with a prefix of the body.
    static func checked(_ response: HTTPResponseSpec) throws -> Data {
        guard (200..<300).contains(response.status) else {
            throw KBLLMError.httpStatus(code: response.status, message: String(decoding: response.body.prefix(300), as: UTF8.self))
        }
        return response.body
    }
}
