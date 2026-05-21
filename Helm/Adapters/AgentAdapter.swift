import Foundation

/// Events the UI cares about — vendor-agnostic. Concrete adapters translate
/// their wire format into this stream.
enum AgentEvent: Sendable {
    /// Vendor session id, surfaced as soon as the agent reports it. Helm
    /// stores this on `Session.vendorSessionId` to enable resume.
    case sessionId(String)

    /// Assistant text increment (a `text_delta` from Claude, an output_text
    /// delta from Codex, etc).
    case assistantTextDelta(String)

    /// One assistant tool invocation begins. `input` is the raw JSON snapshot
    /// available at the start (may be empty — fills in via `toolInputDelta`).
    case toolCallStart(id: String, name: String, input: String)

    /// Streaming JSON fragment for the in-flight tool call.
    case toolInputDelta(id: String, fragment: String)

    /// Result of a tool call (from the agent's own tool runner — not Helm's).
    case toolResult(id: String, output: String, isError: Bool)

    /// One assistant message completes.
    case messageStop

    /// Turn finished. `text` is the final result text the agent reports.
    case finalResult(text: String, isError: Bool)

    /// Surfaced when the adapter or child process errors out.
    case error(String)
}

protocol AgentAdapter: AnyObject {
    /// Where this vendor keeps its sessions on disk + how to enumerate / read
    /// them. `AppStore` uses this to lazily load history when a session is
    /// opened, instead of persisting messages itself.
    var sessionStore: AgentSessionStore { get }

    /// Spawn the agent and stream events back. The returned stream finishes
    /// when the agent exits; throwing tears the conversation down.
    func start(prompt: String,
               session: Session,
               run: RunConfig,
               project: Project) throws -> AsyncThrowingStream<AgentEvent, Error>

    /// Best-effort cancellation. Adapters should SIGTERM the child and let
    /// the stream finish with `.error("cancelled")` or similar.
    func cancel()
}
