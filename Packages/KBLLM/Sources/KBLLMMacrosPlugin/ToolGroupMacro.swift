import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `@ToolGroup` on a type into a `toolBox` property that collects the type's
/// `@Tool` methods. Each entry calls the peer factory `@Tool` generated for that
/// method, which binds the tool to `self`, so the tools capture whatever dependencies
/// the instance holds and stay testable.
public enum ToolGroupMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let toolNames = declaration.memberBlock.members.compactMap { member -> String? in
            guard
                let function = member.decl.as(FunctionDeclSyntax.self),
                hasToolAttribute(function)
            else { return nil }
            return function.name.text
        }

        let factoryCalls = toolNames
            .map { "            \($0)Tool()" }
            .joined(separator: ",\n")
        let toolsLiteral = toolNames.isEmpty ? "[]" : "[\n\(factoryCalls)\n        ]"

        let source = """
        var toolBox: ToolBox {
            ToolBox(tools: \(toolsLiteral))
        }
        """
        return [DeclSyntax(stringLiteral: source)]
    }

    private static func hasToolAttribute(_ function: FunctionDeclSyntax) -> Bool {
        function.attributes.contains { attribute in
            guard case .attribute(let attributeSyntax) = attribute else { return false }
            let name = attributeSyntax.attributeName.as(IdentifierTypeSyntax.self)?.name.text
            return name == "Tool"
        }
    }
}
