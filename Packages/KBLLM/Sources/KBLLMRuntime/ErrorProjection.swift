import Foundation
import KBLLM

public extension ToolResult {
    /// The PUBLIC error-projection seam: render a typed `KBLLMError` into the bytes a
    /// tool result carries. The runtime uses it for an unknown or failing tool so the
    /// model is fed a stable, parseable description it can recover from, instead of the
    /// failure escaping as a thrown error. It is JSON with sorted keys so the same error
    /// always projects to the same bytes, and so a tool name full of hostile characters
    /// (a quote, a percent sign, an emoji) survives intact rather than being mangled by a
    /// hand-rolled formatter that a naive `"\(name)"` interpolation would produce.
    static func errorContent(for error: KBLLMError) -> Data {
        let fields: [String: String]
        switch error {
        case .transport(let url, let underlying):
            fields = ["kind": "transport", "url": url, "underlying": underlying]
        case .httpStatus(let code, let message):
            fields = ["kind": "httpStatus", "code": String(code), "message": message]
        case .httpStatusRetryAfter(let code, let message, let retryAfter):
            fields = [
                "kind": "httpStatus", "code": String(code), "message": message, "retryAfter": String(retryAfter)
            ]
        case .missingCredential(let key):
            fields = ["kind": "missingCredential", "key": key]
        case .decoding(let expected, let fragment):
            fields = ["kind": "decoding", "expected": expected, "fragment": fragment]
        case .unknownTool(let name):
            fields = ["kind": "unknownTool", "name": name]
        case .invalidRequest(let field, let reason):
            fields = ["kind": "invalidRequest", "field": field, "reason": reason]
        case .upstream(let cause):
            fields = ["kind": "upstream", "cause": cause]
        case .cancelled:
            fields = ["kind": "cancelled"]
        case .unavailable(let reason):
            fields = ["kind": "unavailable", "reason": reason]
        case .schemaViolation(let expected, let received):
            fields = ["kind": "schemaViolation", "expected": expected, "received": received]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(fields)) ?? Data()
    }

    /// Build an error result from a typed error via ``errorContent(for:)``. `isError` is
    /// always true because this init exists only for the recoverable-failure path.
    init(erroring error: KBLLMError, toolName: String) {
        self.init(toolName: toolName, isError: true, content: ToolResult.errorContent(for: error))
    }
}
