import Cocoa
import WebKit

// Compile alongside the production bridge. Real termination is tested separately
// using RefreshFixture; this checks identity/policy without touching user apps.
final class NoRedirects: NSObject, URLSessionTaskDelegate {}

@main
enum PolicyTests {
    static func main() {
        let a = RefreshIdentity(pid: 10, bundle: "test.fixture", path: "/fixture.app", launched: 1)
        let future = Date().addingTimeInterval(30)
        precondition(a.valid(current: a, expires: future))
        precondition(!a.valid(current: a, expires: Date().addingTimeInterval(-1)))
        precondition(!a.valid(current: nil, expires: future))
        precondition(!a.valid(current: RefreshIdentity(pid: 10, bundle: a.bundle, path: a.path, launched: 2), expires: future), "PID reuse must not authorize a different app instance")
        precondition(!a.valid(current: RefreshIdentity(pid: 10, bundle: "other.app", path: a.path, launched: 1), expires: future))
        precondition(!a.valid(current: RefreshIdentity(pid: 10, bundle: a.bundle, path: "/other.app", launched: 1), expires: future))
        for id in ["com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.apple.Terminal", "org.alacritty", "com.microsoft.VSCode", "com.apple.finder", "local.devpurge.studio"] {
            precondition(RefreshIdentity.protection(bundle: id, name: "") != nil, id)
        }
        precondition(RefreshIdentity.protection(bundle: "com.other.app", name: "Cursor") != nil)
        precondition(RefreshIdentity.protection(bundle: "test.fixture", name: "Refresh Fixture") == nil)
        let origin = URL(string: "http://127.0.0.1:12345/#fixture")!
        precondition(RefreshIdentity.trustedFrame(source: URL(string: "http://127.0.0.1:12345/"), endpoint: origin, main: true))
        for url in ["http://example.com/", "http://127.0.0.1:12346/", "https://127.0.0.1:12345/", "http://127.0.0.1:12345/other", "http://127.0.0.1:12345/?other", "http://user@127.0.0.1:12345/"] {
            precondition(!RefreshIdentity.trustedFrame(source: URL(string: url), endpoint: origin, main: true))
        }
        precondition(!RefreshIdentity.trustedFrame(source: origin, endpoint: origin, main: false))
        precondition(!RefreshIdentity.trustedFrame(source: origin, endpoint: nil, main: true))
        print("Refresh identity and protected-application checks passed")
    }
}
