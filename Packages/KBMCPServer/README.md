# KBMCPServer

KBMCPServer lets an app host a tool-only MCP (Model Context Protocol) server, so a local agent such as Claude Code can
call into it. It has five parts: a JSON-RPC 2.0 core, closure-based tools, a loopback Streamable HTTP transport on
`NWListener`, a stdio transport for command-line servers, and a lifecycle controller that persists nothing.

It was extracted from Aside's MCPServerKit, with the app-specific tools left behind.

**What it is not.** It is not an MCP client. It has no SSE stream, no `GET` stream, no sessions, and no resources or
prompts: only tools, answered with one JSON response per `POST`. It has no persistence: the app supplies the port, the
token and the enabled flag, and stores whatever changes. It is not portable to Android, because it uses Network,
Security and os. It is not a general HTTP server either; it answers exactly one route.

## Install

KBMCPServer is a product of the KBKits package:

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBMCPServer", package: "KBKits")
    ])
]
```

It needs nothing outside the SDK: Foundation, Network, Security, Observation, Synchronization and os.

## Quick start

Define tools, put them in a handler, and give the handler to a controller:

```swift
import KBMCPServer

let echo = MCPTool(
    name: "echo",
    title: "Echo",
    description: "Returns its text argument.",
    inputSchema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]],
    readOnly: true
) { arguments in
    .string(try MCPArguments(arguments).string("text"))
}

let handler = MCPRequestHandler(
    serverName: "myapp",
    serverVersion: "1.0.0",
    instructions: "Tools for reading MyApp's library.",
    tools: [echo]
)

// The app owns persistence: read these from wherever it keeps settings.
let controller = MCPServerController(
    port: MCPServerController.defaultPort,
    token: storedToken ?? MCPServerController.makeToken(),
    isEnabled: storedEnabled,
    handler: handler
)
await controller.start()                            // does nothing unless enabled
let newToken = await controller.regenerateToken()   // persist it; the old one stops working
```

`MCPServerController` is `@MainActor`, so create and call it from the main actor.

Register the server with Claude Code by printing `controller.claudeCodeCommand(name: "myapp")`:

```sh
claude mcp add --transport http myapp http://127.0.0.1:47821/mcp --header "Authorization: Bearer <token>"
```

### Over stdio

A command-line tool can serve the same handler over stdio instead, for clients that launch the server as a subprocess
(`claude mcp add myapp -- /path/to/tool mcp`):

```swift
try await MCPStdioTransport(handler: handler).serveStandardIO()
```

Each line on standard input is one JSON-RPC message, and each reply is one line on standard output, so log to
standard error. `serve(_:write:)` takes any `AsyncSequence` of lines instead, which is how the tests drive it.

### Without the controller

`MCPHTTPServer(handler:token:)` can be used on its own. `start(port:)` returns `.running(port:)` with the port actually
bound (pass 0 for any free port) or `.failed(message)`, and `stop()` is synchronous. The optional `connectionTimeout`
parameter defaults to `MCPHTTPServer.defaultConnectionTimeout` (30 seconds).

## Main types

- `MCPRequestHandler`: the transport-independent core. `handle(body:)` takes one request body and returns the reply
  bytes, or nil when nothing needs an answer. `supportedProtocolVersions` lists the protocol versions it speaks.
- `MCPTool`: a name, title, description, `inputSchema`, `readOnly` and `destructive` flags (both default to false), and
  an async throwing handler from arguments to a result. The flags become the `readOnlyHint`, `destructiveHint` and
  `idempotentHint` annotations; `idempotentHint` follows `readOnly`, and `openWorldHint` is always false.
- `MCPArguments`: typed reads from a call's arguments that throw agent-readable errors, such as
  `Missing required string argument 'id'.` It has `string(_:)` (required and non-empty), `optionalString(_:)`,
  `optionalInt(_:)`, `optionalBool(_:)`, `optionalStringArray(_:)`, `uuid(_:)` and `optionalUUIDArray(_:)`.
- `MCPToolError`: throw it from a handler to give the agent a message it can act on.
- `MCPValue`: the JSON document type for envelopes, arguments and results. It is expressible by string, integer,
  Boolean, array and dictionary literals, and has `stringValue`, `intValue`, `boolValue`, `arrayValue`, `objectValue`
  and a string subscript.
- `MCPStdioTransport`: newline-delimited JSON-RPC over standard input and output (or any line sequence), handled in
  order, one message at a time.
- `MCPHTTPServer`: the loopback transport and its `State` (`stopped`, `running(port:)`, `failed`).
- `MCPServerController`: an `@MainActor @Observable` lifecycle around one server. It has `start()`, `setEnabled(_:)`,
  `setPort(_:)`, `regenerateToken()`, `stop()`, `endpoint`, `claudeCodeCommand(name:)` and `makeToken()`, and exposes
  `isEnabled`, `port`, `token` and `state` for a settings screen to observe.

### Why `MCPValue` and not `JSONValue`

Aside's original type was `JSONValue`. Consuming apps (Aside first) already declare a public `JSONValue` of their own,
so importing both modules would make the bare name ambiguous in every file that mentions it. Module-qualifying each
use would work, but only if every call site did it. A distinct name removes the clash.

## Protocol

- Methods: `initialize`, `ping`, `tools/list` and `tools/call`. Anything else is `-32601 Method not found: <method>`.
- Protocol versions, newest first: `2025-06-18`, `2025-03-26`, `2024-11-05`. `initialize` echoes a supported requested
  version and otherwise answers `2025-06-18`.
- A message with no `id` (or `id: null`) is a notification, and one with no `method` is a client response. Neither gets
  a reply; over HTTP that is `202 Accepted` with an empty body. A batch answers only its requests, in order.
- A tool that throws produces a result with `isError: true`, not a JSON-RPC error, so the model reads the message and
  can retry. `MCPToolError` passes its message through unchanged; any other error becomes
  `Tool failed: <localizedDescription>`. An unknown tool is `-32602`.
- A string result is returned as text verbatim. Any other result is pretty-printed JSON text with sorted keys, because
  client support for structured content varies.

## Security model

The server exposes whatever its tools can reach, so it is locked to the local user.

- **Loopback only.** The listener requires the loopback interface; it is never reachable from the LAN.
- **Bearer token.** Every request needs `Authorization: Bearer <token>`, compared in constant time. `makeToken()`
  returns 32 bytes from `SecRandomCopyBytes` as 64 lowercase hex characters. Regenerating the token invalidates the old
  one at once, so agents must be registered again.
- **Host and Origin checks (DNS rebinding).** `Host` must be `localhost`, `127.0.0.1` or `::1`, and an `Origin`, when
  present, must name one of those hosts. A web page that rebinds its own domain to 127.0.0.1 still sends its own name
  and is refused with 403. A bare `::1` Host is accepted, but an unbracketed `::1:8080` is refused as ambiguous (it is
  itself an IPv6 address); a port on IPv6 needs brackets, as in `[::1]:8080`.
- **One route.** Only `POST /mcp` is served (a query string is ignored). Other paths are 404, and any other method is
  405 with `Allow: POST`, which a client reads as "no SSE stream offered".
- **Size caps.** Headers are capped at 32 KiB (431). Bodies are capped at 8 MiB (413), refused on the declared
  `Content-Length` before any of the body is read. `Transfer-Encoding` of any kind is 501.
- **Timeouts.** A connection that stalls is cancelled after 30 seconds (configurable through `connectionTimeout`).
- **One exchange per connection.** Each response carries `Connection: close` and `Cache-Control: no-store`, and the
  connection is closed after it is written.

The checks run in a fixed order: Host, Origin, token, path, method. A foreign page learns nothing beyond the first
check it fails.

## Invariants

- **Tools are listed in registration order; when two share a name, the first one runs.**
- **Request ids echo exactly.** A whole number stays an integer on the wire (`7`, never `7.0`).
- **`.running(port:)` is the bound port**, never the requested 0. A port already in use, or a listener that can only
  wait, resolves to `.failed` rather than hanging `start`. The message for a clash contains
  `Port <p> is already in use.`
- **The controller never reads or writes storage.** `setPort(_:)` accepts 0 or 1024 and above and ignores privileged
  ports; each accepted change restarts the server when it is enabled. `endpoint` reports the bound port while running
  and the configured port otherwise.

## Tests

From the repository root:

```sh
swift test --filter KBMCPServerTests
```

The loopback tests bind real ports on 127.0.0.1; the stdio tests feed the transport an in-memory line sequence.
