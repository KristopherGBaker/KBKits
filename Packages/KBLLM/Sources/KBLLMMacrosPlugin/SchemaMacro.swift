import SwiftSyntax
import SwiftSyntaxMacros

/// A stored property of a `@Schema` type, reduced to what the schema needs.
private struct SchemaProperty {
    var name: String
    var type: String
    var isOptional: Bool
    var description: String?
}

/// Expands `@Schema` on a type into a `static let schema: JSONSchema` describing its
/// stored properties, with each property's JSON type derived from its Swift type and
/// its description from its own doc comment. Structured output shares the one schema
/// vocabulary the tools use, so there is a single place types are described.
public enum SchemaMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let properties = storedProperties(of: declaration)
        let propertiesLiteral: String
        if properties.isEmpty {
            propertiesLiteral = "[:]"
        } else {
            let pairs = properties
                .map { property in
                    let schema = MacroSupport.schemaExpression(for: property.type, description: property.description)
                    return "            \(MacroSupport.stringLiteral(property.name)): \(schema)"
                }
                .joined(separator: ",\n")
            propertiesLiteral = "[\n\(pairs)\n        ]"
        }
        let requiredList = properties
            .filter { !$0.isOptional }
            .map { MacroSupport.stringLiteral($0.name) }
            .joined(separator: ", ")

        let source = """
        static let schema: JSONSchema = JSONSchema.object(
            properties: \(propertiesLiteral),
            required: [\(requiredList)],
            description: nil
        )
        """
        return [DeclSyntax(stringLiteral: source)]
    }

    private static func storedProperties(of declaration: some DeclGroupSyntax) -> [SchemaProperty] {
        var result: [SchemaProperty] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            // A computed property (a binding with an accessor block) is not stored, so
            // it is not part of the value's structured shape.
            let isComputed = variable.bindings.contains { $0.accessorBlock != nil }
            if isComputed { continue }
            let doc = MacroSupport.docComment(for: variable.leadingTrivia)
            let overviewDescription = doc.overview.isEmpty ? nil : doc.overview
            for binding in variable.bindings {
                guard
                    let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                    let typeAnnotation = binding.typeAnnotation?.type
                else { continue }
                let rawType = typeAnnotation.trimmedDescription
                let isOptional = rawType.hasSuffix("?")
                let unwrapped = isOptional ? String(rawType.dropLast()) : rawType
                result.append(
                    SchemaProperty(
                        name: identifier,
                        type: unwrapped,
                        isOptional: isOptional,
                        description: overviewDescription
                    )
                )
            }
        }
        return result
    }
}
