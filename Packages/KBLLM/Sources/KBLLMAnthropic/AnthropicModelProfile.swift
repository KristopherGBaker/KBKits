import Foundation

/// What the adapter needs to know about one Anthropic model id, read from the id alone. The
/// Messages API is one wire, but which request shapes a model accepts differs by generation:
/// forced `tool_choice` is a 400 on the 5.x models, structured outputs exist only from the 4.5
/// generation on, and the dynamic-filtering search tool only on Sonnet and Opus 4.6 and later.
///
/// The id is parsed rather than matched against a list, so a dated snapshot
/// (`claude-sonnet-4-5-20250929`), a cloud-prefixed id (`anthropic.claude-opus-4-6-v1:0`) and the
/// pre-4 word order (`claude-3-5-sonnet-20241022`) all read the same way, and a model released
/// after this code still lands in the right generation. An id with no Claude version in it (a
/// local server's model, a gateway alias) gets the conservative profile: the legacy structured
/// route and the basic search tool, which every model accepts.
struct AnthropicModelProfile {
    /// A Claude generation, `major.minor`. A bare major (`claude-sonnet-4`) is `.0`.
    struct Version: Comparable {
        let major: Int
        let minor: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
        }
    }

    /// The model family word (`sonnet`, `opus`, `haiku`, `fable`, ...), or nil when absent.
    let family: String?
    /// The Claude version, or nil for an id that names none.
    let version: Version?

    init(_ model: String) {
        let lowered = model.lowercased()
        guard let claude = lowered.range(of: "claude") else {
            family = nil
            version = nil
            return
        }
        // Tokens after `claude`, split on every separator an id uses (`-`, `.`, `@`, `:`).
        let tokens = lowered[claude.upperBound...]
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        family = tokens.first { $0.allSatisfy(\.isLetter) }
        // A version part is one or two digits; a snapshot date (eight) never is. The minor must
        // directly follow the major, so `claude-sonnet-4-20250514` is 4.0 and the `0` of a
        // trailing `-v1:0` is never read as a minor.
        func versionPart(_ index: Int) -> Int? {
            guard tokens.indices.contains(index), tokens[index].count <= 2 else { return nil }
            return Int(tokens[index])
        }
        guard let majorIndex = tokens.indices.first(where: { versionPart($0) != nil }),
              let major = versionPart(majorIndex)
        else {
            version = nil
            return
        }
        version = Version(major: major, minor: versionPart(majorIndex + 1) ?? 0)
    }

    /// Whether the model is at least `major.minor`. False for an id with no version.
    private func isAtLeast(_ major: Int, _ minor: Int) -> Bool {
        guard let version else { return false }
        return version >= Version(major: major, minor: minor)
    }

    /// Structured outputs (`output_config.format`): Sonnet, Opus and Haiku 4.5 and every 5.x
    /// model. Anything older, or unversioned, takes the legacy tool route instead.
    var supportsStructuredOutputs: Bool {
        isAtLeast(4, 5)
    }

    /// The dynamic-filtering search tool (`web_search_20260209`) is documented for Sonnet and
    /// Opus 4.6 onward. Every other model, Haiku and the unversioned included, gets the basic one.
    var supportsDynamicWebSearch: Bool {
        (family == "sonnet" || family == "opus") && isAtLeast(4, 6)
    }

    /// Assistant prefill (a request whose last turn is the assistant's) is a 400 from 4.6 on.
    var rejectsPrefill: Bool {
        isAtLeast(4, 6)
    }

    /// Which sampling parameters (`temperature`, `top_p`) the model accepts.
    enum Sampling: Equatable {
        /// Both, together or apart: 4.1 and older, and any id this adapter cannot place (a local
        /// server keeps the controls it has always been sent).
        case any
        /// Either, but not both in one request: the 4.x models newer than 4.1 (Opus and Sonnet
        /// 4.5 and 4.6, Haiku 4.5).
        case oneOf
        /// Neither. Removed on Opus 4.7 and later and on the 5.x models (a 400 for any value),
        /// and a 400 for any non-default value on the rest of 5.x, so a hint is only ever safe
        /// to drop there.
        case none
    }

    var sampling: Sampling {
        guard let version else { return .any }
        if version.major >= 5 || (family == "opus" && isAtLeast(4, 7)) { return .none }
        return isAtLeast(4, 2) ? .oneOf : .any
    }
}
