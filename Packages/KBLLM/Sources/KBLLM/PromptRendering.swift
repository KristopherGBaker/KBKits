import Foundation

// Rendering conversation history into ONE prompt string.
//
// This lives in the core module, not in an adapter, because it is pure `Message` to `String`
// and names no provider type. Every backend whose interface is a single string rather than a
// message array needs exactly this, and needs it to make the same choices: Apple's on-device
// framework does, and so does a locally loaded model whose generate takes a prompt. A second
// copy would be a second set of choices about what survives the flattening.
//
// Foundation Models takes a prompt and instructions, with no structured channel for a tool
// call or its result. The HTTP providers have one, so they carry that history natively; here
// it has to be written into the prompt or it is LOST. Losing it is not cosmetic: the runtime
// answers a tool call by appending the result and calling again, so a prompt that omits the
// result is byte-identical to the previous turn's. The model then asks for the same tool
// again, and again, until `maxToolRoundTrips` stops the run with no answer. That failure was
// observed live on device before this existed.
public enum PromptRendering {
    /// The system instructions, or nil when the caller sent none, so nothing is injected
    /// where the caller asked for nothing.
    public static func instructions(from request: ModelRequest) -> String? {
        let text = render(request.messages.filter { $0.role == .system })
        return text.isEmpty ? nil : text
    }

    /// The prompt: every non-system turn, in order, with tool calls and tool results
    /// rendered as text so the model can see what it already asked for and what came back.
    public static func prompt(from request: ModelRequest) -> String {
        render(request.messages.filter { $0.role != .system })
    }

    private static func render(_ messages: [Message]) -> String {
        messages
            .flatMap { message in message.content.map { (message.role, $0) } }
            .compactMap(line(role:content:))
            .joined(separator: "\n")
    }

    private static func line(role: MessageRole, content: MessageContent) -> String? {
        switch content {
        case .text(let text):
            return text.isEmpty ? nil : text
        case .toolCall(let call):
            // Naming the arguments matters: without them the model cannot tell a repeat
            // request from the one it already made.
            let arguments = String(data: call.arguments, encoding: .utf8) ?? "{}"
            return "[assistant called tool \(call.name) with \(arguments)]"
        case .toolResult(_, let result):
            let body = result.text ?? ""
            let outcome = result.isError ? "failed" : "returned"
            return "[tool \(result.toolName) \(outcome): \(body)]"
        case .image:
            // Renders nothing rather than inventing a text description of bytes the backend was
            // never given. A caller whose backend cannot see images should reject the request
            // outright (as `AppleModel` does) rather than rely on this silent drop.
            return nil
        }
    }
}
