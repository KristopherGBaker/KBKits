import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// A parameter of a `@Tool` function, reduced to what the generated code needs.
private struct ToolParameter {
    var jsonKey: String
    var callLabel: String?
    var type: String
    var isOptional: Bool
    var description: String?
}

/// The shape of a `@Tool` function that the generated factory depends on. Grouped so
/// the render helpers take a single value rather than a long parameter list.
private struct ToolShape {
    var name: String
    var argumentsTypeName: String
    var overview: String
    var isAsync: Bool
    var isThrowing: Bool
    var returnsValue: Bool
    /// Whether the CALL needs `await` even though the function is not declared `async`.
    ///
    /// A method on an actor, or on a type carrying a global actor like `@MainActor`, is
    /// isolated: calling it from the generated invoker (which is nonisolated and escaping)
    /// crosses into that actor and so must be awaited. The function's own `async` keyword
    /// does not say this, which is why it is tracked separately.
    var isIsolated: Bool
}

/// Expands `@Tool` on a function into a peer `<name>Tool()` factory that returns a
/// `Tool`. The factory works both as a free function and as an instance method: the
/// invoker calls the annotated function unqualified, which resolves to `self.method`
/// inside a `@ToolGroup` type (so it captures injected deps) and to the free function
/// at file scope.
public enum ToolMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError.message("@Tool can only be attached to a function")
        }

        let name = function.name.text
        let doc = MacroSupport.docComment(for: function.leadingTrivia)
        let parameters = toolParameters(of: function, doc: doc)
        let effects = function.signature.effectSpecifiers
        let isAsync = effects?.asyncSpecifier != nil
        let isThrowing = effects?.throwsClause != nil
        let returnsValue = function.signature.returnClause != nil

        // The arguments type is emitted as a PEER, not declared inside the invoke closure.
        // A closure-local type with a synthesized Decodable conformance crashes the
        // compiler: LLVM's VerifierPass reports "Global is external, but doesn't have
        // external or weak linkage!" and swift-frontend aborts with signal 6. Verified on
        // Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), both debug and release.
        //
        // Before changing this, note the trap: an incremental build REUSES the cached macro
        // expansion, so the closure-local form appears to build and test clean. The crash
        // only appears after `rm -rf .build`. Equivalent hand-written code compiles fine,
        // so it does not reproduce outside macro expansion either. Reproduce with a clean
        // build before concluding this workaround is obsolete.
        // Whether this tool is a METHOD or a free function decides how the invoker closure
        // captures. A method on a reference type cannot call itself unqualified from an
        // escaping closure ("implicit use of 'self'"), which made `@ToolGroup` unusable on
        // exactly the types an app puts its state in: `@MainActor final class` controllers
        // and observable view models. An explicit `[self]` capture fixes that and is equally
        // valid on a value type, but it is not expressible at file scope, where there is no
        // `self` at all, so the two cases must be told apart.
        let isMethod = context.lexicalContext.contains { syntax in
            syntax.is(ClassDeclSyntax.self)
                || syntax.is(StructDeclSyntax.self)
                || syntax.is(ActorDeclSyntax.self)
                || syntax.is(EnumDeclSyntax.self)
                || syntax.is(ExtensionDeclSyntax.self)
        }
        let shape = ToolShape(
            name: name,
            argumentsTypeName: "\(name)ToolArguments",
            overview: doc.overview,
            isAsync: isAsync,
            isThrowing: isThrowing,
            returnsValue: returnsValue,
            isIsolated: isIsolated(function: function, in: context, isMethod: isMethod)
        )
        for parameter in parameters where !MacroSupport.isRecognizedSchemaType(parameter.type) {
            // Not an error: a String-backed enum maps to `string` correctly, and refusing it
            // would break working tools. But a nested struct maps to `string` INCORRECTLY, and
            // the symptom is a model dutifully sending a string the decoder then rejects, which
            // is a long way from the cause.
            context.diagnose(
                Diagnostic(
                    node: Syntax(function),
                    message: MacroWarning(
                        "@Tool cannot map '\(parameter.type)' to a JSON Schema type, so "
                            + "'\(parameter.jsonKey)' is described to the model as a string. "
                            + "That is correct for a String-backed enum and wrong for a "
                            + "structured type; prefer a scalar, an array of scalars, or a "
                            + "String-backed enum."
                    )
                )
            )
        }
        let argumentsSource = renderArguments(typeName: shape.argumentsTypeName, parameters: parameters)
        let factorySource = renderFactory(shape: shape, parameters: parameters, isMethod: isMethod)
        return [DeclSyntax(stringLiteral: argumentsSource), DeclSyntax(stringLiteral: factorySource)]
    }

    /// Whether calling this function from the generated invoker crosses into an actor.
    ///
    /// Three ways that happens: the method lives on an `actor`, the method itself carries a
    /// global actor attribute, or its enclosing type does. A `nonisolated` method is exempt
    /// however it is nested, which is the one case that must not get a spurious `await`.
    ///
    /// This is syntax, not type resolution, so it recognizes a global actor by the shape of
    /// the attribute name (`@MainActor`, `@SomeCustomActor`) rather than by resolving it.
    /// An unrecognized custom global actor therefore still fails to compile, the same way it
    /// did before this existed, and the fix is the same: declare the method `async`.
    private static func isIsolated(
        function: FunctionDeclSyntax,
        in context: some MacroExpansionContext,
        isMethod: Bool
    ) -> Bool {
        guard isMethod else { return false }
        if function.modifiers.contains(where: { $0.name.text == "nonisolated" }) { return false }
        if carriesGlobalActor(function.attributes) { return true }

        return context.lexicalContext.contains { syntax in
            if syntax.is(ActorDeclSyntax.self) { return true }
            if let decl = syntax.as(ClassDeclSyntax.self) { return carriesGlobalActor(decl.attributes) }
            if let decl = syntax.as(StructDeclSyntax.self) { return carriesGlobalActor(decl.attributes) }
            if let decl = syntax.as(EnumDeclSyntax.self) { return carriesGlobalActor(decl.attributes) }
            if let decl = syntax.as(ExtensionDeclSyntax.self) { return carriesGlobalActor(decl.attributes) }
            return false
        }
    }

    /// Whether an attribute list carries something that looks like a global actor: an
    /// attribute whose name ends in `Actor`. `@MainActor` is the one that matters in practice.
    private static func carriesGlobalActor(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self),
                  let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text
            else { return false }
            return name.hasSuffix("Actor")
        }
    }

    private static func renderArguments(typeName: String, parameters: [ToolParameter]) -> String {
        let bindings = parameters
            .map { "    let \($0.jsonKey): \($0.type)" }
            .joined(separator: "\n")
        if parameters.isEmpty {
            return "struct \(typeName): Decodable {}"
        }
        return """
        struct \(typeName): Decodable {
        \(bindings)
        }
        """
    }

    private static func toolParameters(
        of function: FunctionDeclSyntax,
        doc: DocComment
    ) -> [ToolParameter] {
        function.signature.parameterClause.parameters.map { parameter in
            let firstName = parameter.firstName.text
            let secondName = parameter.secondName?.text
            let jsonKey = (firstName == "_" ? secondName : firstName) ?? firstName
            let callLabel = firstName == "_" ? nil : firstName
            let type = parameter.type.trimmedDescription
            return ToolParameter(
                jsonKey: jsonKey,
                callLabel: callLabel,
                type: type,
                isOptional: MacroSupport.unwrapOptional(type).isOptional,
                description: doc.parameters[jsonKey]
            )
        }
    }

    private static func renderFactory(
        shape: ToolShape,
        parameters: [ToolParameter],
        isMethod: Bool
    ) -> String {
        let propertiesLiteral: String
        if parameters.isEmpty {
            propertiesLiteral = "[:]"
        } else {
            let pairs = parameters
                .map { parameter in
                    let key = MacroSupport.stringLiteral(parameter.jsonKey)
                    let schema = MacroSupport.schemaExpression(for: parameter.type, description: parameter.description)
                    return "                    \(key): \(schema)"
                }
                .joined(separator: ",\n")
            propertiesLiteral = "[\n\(pairs)\n                ]"
        }
        // An optional parameter is not required. Listing it anyway tells the model it must
        // supply a value for something the function was written to do without.
        let requiredList = parameters
            .filter { !$0.isOptional }
            .map { MacroSupport.stringLiteral($0.jsonKey) }
            .joined(separator: ", ")
        let callArguments = parameters
            .map { parameter in
                if let label = parameter.callLabel {
                    "\(label): __args.\(parameter.jsonKey)"
                } else {
                    "__args.\(parameter.jsonKey)"
                }
            }
            .joined(separator: ", ")
        // `await` is needed when the function says `async` OR when calling it crosses into an
        // actor. Emitting it in neither case fails to compile; emitting it in both cases when
        // neither applies is only a warning, so the detection errs toward silence.
        let needsAwait = shape.isAsync || shape.isIsolated
        let effectPrefix = "\(shape.isThrowing ? "try " : "")\(needsAwait ? "await " : "")"
        let name = shape.name
        let argumentsTypeName = shape.argumentsTypeName
        let returnsValue = shape.returnsValue
        let nameLiteral = MacroSupport.stringLiteral(name)
        // A method captures `self` explicitly so a reference-type group compiles; a free
        // function has no `self` to capture.
        let captureList = isMethod ? "[self] " : ""
        let overviewLiteral = MacroSupport.stringLiteral(shape.overview)

        let resultLines: String
        if returnsValue {
            resultLines = """
                        let __result = \(effectPrefix)\(name)(\(callArguments))
                        let __encoded = try JSONEncoder().encode(__result)
                        return ToolResult.success(toolName: \(nameLiteral), content: __encoded)
            """
        } else {
            resultLines = """
                        \(effectPrefix)\(name)(\(callArguments))
                        return ToolResult.success(toolName: \(nameLiteral), content: Data(\"null\".utf8))
            """
        }

        return """
        func \(name)Tool() -> Tool {
            return Tool(
                definition: ToolDefinition(
                    name: \(nameLiteral),
                    description: \(overviewLiteral),
                    parameters: JSONSchema.object(
                        properties: \(propertiesLiteral),
                        required: [\(requiredList)],
                        description: nil
                    )
                ),
                invoke: { \(captureList)(__data: Data) async -> ToolResult in
                    do {
                        let __args = try JSONDecoder().decode(\(argumentsTypeName).self, from: __data)
        \(resultLines)
                    } catch {
                        return ToolResult.failure(toolName: \(nameLiteral), message: String(describing: error))
                    }
                }
            )
        }
        """
    }
}

/// A macro warning: something the author should know without the build failing.
struct MacroWarning: DiagnosticMessage {
    let message: String
    let diagnosticID = MessageID(domain: "KBLLMMacros", id: "unmappable-parameter-type")
    let severity: DiagnosticSeverity = .warning

    init(_ message: String) {
        self.message = message
    }
}

/// A minimal diagnostic error for the macros.
struct MacroError: Error, CustomStringConvertible {
    let description: String
    static func message(_ text: String) -> MacroError { MacroError(description: text) }
}
