import Foundation
import KBLLM

// The macro fixtures used across the suite. Every tool/schema/parameter description
// is written ONCE, here, in a doc comment; the source-content test proves no copy
// exists anywhere else in the package, and the schema tests read these very lines back
// to compare against what the macro generated.

/// Adds two integers and returns their sum.
/// - Parameter a: The first addend to combine.
/// - Parameter b: The second addend to combine.
@Tool
// The single-letter argument names mirror the tool's JSON contract; the house
// identifier-length rule does not apply to a math tool's operands.
// swiftlint:disable:next identifier_name
func add(a: Int, b: Int) -> Int {
    a + b
}

/// Builds a greeting for the given individual.
/// - Parameter subject: The name of the individual to greet.
@Tool
func greet(subject: String) -> String {
    "Hello, \(subject)!"
}

/// A person, used to exercise `@Schema` structured output.
@Schema
struct Person {
    /// The full display name of the person.
    let displayName: String
    /// The age of the person in whole years.
    let age: Int
}

/// A group of tools that captures an injected base value, so a tool's result can
/// reflect a dependency rather than only its arguments.
@ToolGroup
struct MathTools {
    let base: Int

    /// Adds the injected base value to the input.
    /// - Parameter value: The number to add to the configured base.
    @Tool
    func addBase(value: Int) -> Int {
        base + value
    }
}

/// A REFERENCE-TYPE tool group that mutates state its instance owns. This is the shape an
/// app actually has (a `@MainActor final class` controller or observable view model), and
/// it is a distinct compile case from a struct group: a method on a reference type cannot
/// call itself unqualified from the generated escaping closure, so the invoker must capture
/// `self` explicitly. A struct group compiling proves nothing about this one.
@MainActor
@ToolGroup
final class MutableCounterTools {
    private(set) var total = 0

    /// Adds an amount to the running total held by this instance.
    /// - Parameter amount: The amount to add.
    @Tool
    func addToTotal(amount: Int) async -> Int {
        total += amount
        return total
    }
}

/// An ACTOR group whose tool method is NOT declared `async`.
///
/// This is the case that did not compile before isolation detection existed: the generated
/// invoker is nonisolated and escaping, so calling an actor-isolated method from it needs
/// `await` even though the method itself says nothing about async. The existing reference-type
/// fixture happens to declare its method `async`, so it could not have caught this.
@ToolGroup
actor IsolatedCounterTools {
    private var total = 0

    /// Adds an amount to the running total held by this actor.
    /// - Parameter amount: How much to add to the actor's running total.
    @Tool
    func addIsolated(amount: Int) -> Int {
        total += amount
        return total
    }
}

/// A `@MainActor` group whose tool method is NOT declared `async`, which failed the same way
/// and is the shape `@ToolGroup`'s own documentation points at (a controller or view model).
@MainActor
@ToolGroup
final class MainActorTools {
    /// Doubles a number.
    /// - Parameter value: The number this main-actor tool doubles.
    @Tool
    func doubleValue(value: Int) -> Int {
        value * 2
    }
}

/// A tool with an OPTIONAL parameter, which must be described by its wrapped type and left out
/// of `required`.
/// - Parameter tags: The tags to apply.
/// - Parameter limit: An optional cap on how many to keep.
@Tool
func summarizeTags(tags: [String], limit: Int?) -> [String] {
    Array(tags.prefix(limit ?? tags.count))
}
