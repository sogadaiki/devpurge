# Manual ended-job recovery

Studio → **レンダリングの片付け** → **終了済みの残骸を確認**.
Select an eligible browser to request a graceful close. Then use the existing
verified-copy cleanup for remaining redundant bundles. These are separate
manual actions. No scheduler or login job is enabled.

Scope: orphaned Remotion Chrome headless shells from registered render-care
projects. General Node, Godot, MCP, AI clients, editors and active renderers are
not terminated. AI cannot authorize process termination; Luna/Terra still review
the separate verified-copy file cleanup.

Eligibility is checked twice during inspection and again on execution of a
five-minute, single-use ticket:

- Own-user executable at the registered Remotion installation path.
- Parent PID 1, at least one hour old, same birth time and executable.
- All children belong to that browser installation and current user.
- Complete process/open-file evidence; no other renderer or source Node process.
- Private Puppeteer profile directly under the user's Darwin temporary root.
- One loopback DevTools listener matching the profile's browser UUID endpoint,
  no controller connection or other browser-tree TCP sockets.
- Only page targets; nonblank targets are local `/index.html` pages whose
  servers refuse connections on IPv4 and IPv6. Timeouts, unknown pages, live
  servers, partial evidence and state changes mean keep.

The official CDP [Browser.close](https://chromedevtools.github.io/devtools-protocol/tot/Browser/#method-close)
command is sent through the verified UUID endpoint using a masked WebSocket
frame and validated handshake. After connecting, only the engine's own
controller connection is allowed, and process/render-server state is checked
again. There is no OS-wide lock preventing external processes from starting or
attaching afterward; this is conservative best-effort evidence, not atomic
coordination with an external renderer.

No signals, forced termination, swap deletion, arbitrary PID endpoint, or
fallback bypassing failed evidence. Every original process identity, including
reparented children, must disappear before the engine reports closed.

State: `~/Library/Application Support/devpurge/job-recovery/`. Durable intent
precedes the close command. Receipts distinguish confirmed, uncertain and failed
closure and measure free-space change, including changes from other work.
macOS controls swap shrinkage; process memory is not a disk-recovery estimate.

```sh
devpurge job-recovery scan
devpurge job-recovery status
devpurge job-recovery apply --ticket <id-from-current-scan>
```

App and CLI share an exclusive operation lock. Studio token/origin checks and
its cleanup lock protect the API. Existing jobs and the render-care `enabled`
preference are unchanged.

## Evidence boundary

On 2026-10-27, read-only inspection qualified one ten-process orphan browser
tree. The user rebooted before any close command was sent. Free space changed
from 99.67 GB in the last pre-reboot sample to 161.32 GB in the initial
post-reboot sample: about 61.65 GB gained (decimal GB). The browser disappeared.
This is a reboot observation, not an app cleanup result. Local evidence is
`job-recovery/reboot-20261027.json`, with a slightly later post-reboot sample
that differs as other work changes disk usage.

Safety tests use disposable fixtures and a local WebSocket server. A real
qualified user-process close is not claimed from that reboot or those tests.
