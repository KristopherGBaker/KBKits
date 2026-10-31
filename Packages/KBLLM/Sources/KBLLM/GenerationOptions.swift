import Foundation

/// The provider-neutral sampling controls a caller can set on a request. Every knob is
/// OPTIONAL and defaults to nil, and nil means OMITTED: an adapter emits no wire key for an
/// unset knob, so the provider's own default holds rather than a value KBLLM invented. Only
/// the controls every supported provider genuinely exposes live here (temperature, a
/// maximum-output-token count, top-p, and greedy decoding); anything provider-specific stays
/// out of the neutral core, which is what keeps one request driving every adapter. Adding the
/// next shared knob is one field here plus one line in each renderer.
///
/// `temperature`, `topP` and `sampling` are HINTS: an adapter DROPS one the addressed model
/// rejects rather than failing the request. Anthropic's Opus 4.7+ and 5.x models are sent none
/// of them, and its 4.x models newer than 4.1 are sent only `temperature` when both it and
/// `topP` are set.
public struct GenerationOptions: Sendable, Equatable {
    /// The sampling temperature. nil leaves the provider's own default in force.
    public var temperature: Double?
    /// The maximum number of output tokens to generate. nil leaves the provider's default,
    /// EXCEPT on Anthropic, whose wire requires the field, so that adapter substitutes a
    /// documented fallback only when this is nil (a caller value is always honoured).
    public var maxOutputTokens: Int?
    /// Nucleus sampling (top-p). nil leaves the provider's default; on Apple it maps to the
    /// on-device nucleus threshold, and a nil value fabricates no sampling mode.
    public var topP: Double?
    /// How the next token is chosen, beyond temperature and top-p. nil (the default) leaves
    /// the provider's own sampling in force and adds nothing to any request.
    ///
    /// `.greedy` asks for deterministic decoding: always the most likely token. It WINS over a
    /// `temperature` or `topP` also set, on every adapter, because both only shape a random draw
    /// that greedy decoding never makes. Where each provider enforces it:
    ///
    /// - Apple (on-device and Private Cloud Compute): the Foundation Models framework's own
    ///   greedy sampling mode (`SamplingMode.greedy`), which is true greedy decoding; no
    ///   temperature and no nucleus mode are passed beside it.
    /// - Anthropic: `temperature: 0` alone, on a model that takes sampling parameters (4.1 and
    ///   older, the 4.x models up to Opus 4.6, and any id the adapter cannot place). Opus 4.7+
    ///   and the 5.x models removed sampling parameters, so there it is dropped like any other
    ///   sampling hint and the model's own sampling holds.
    /// - OpenAI (and the servers that speak its wire): `temperature: 0` alone, sent to every
    ///   model the way a caller's temperature already is.
    ///
    /// Temperature 0 is the closest those HTTP APIs come; neither promises bit-identical
    /// answers across calls.
    public var sampling: Sampling?

    /// A sampling strategy a caller can ask for by name rather than by tuning numbers.
    public enum Sampling: Sendable, Equatable {
        /// Deterministic decoding: always the single most likely next token.
        case greedy
    }

    public init(
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        topP: Double? = nil,
        sampling: Sampling? = nil
    ) {
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.topP = topP
        self.sampling = sampling
    }
}
