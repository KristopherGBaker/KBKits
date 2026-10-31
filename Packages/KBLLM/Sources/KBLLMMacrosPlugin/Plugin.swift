import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct KBLLMMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        ToolMacro.self,
        SchemaMacro.self,
        ToolGroupMacro.self
    ]
}
