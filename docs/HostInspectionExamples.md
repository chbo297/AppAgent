# Host inspection examples

Normal host inspection needs no `scope` parameter or additional model call:

```json
{"op":"ui_hierarchy"}
{"op":"ui_hierarchy","detail":"full"}
{"op":"class_list","filter":"Checkout"}
```

These `app_runtime_inspect` calls exclude AppAgent-owned targets. `full` only
increases detail. Use the returned `W<n>:` handles for subsequent view calls;
the handle is not a filtered-window index.

Only when the user asks to inspect the SDK, request a wider scope:

```json
{"op":"ui_hierarchy","scope":"appagent"}
{"op":"ui_hierarchy","scope":"all"}
```

The tool asks for approval through `.appAgentInspection`. Permission lasts for
the current turn, with separate read and mutation decisions. No responder means
denial. SDK approval does not override read-only mode or operation authorization.

## Screenshot artifacts

`screenshot` returns an inline image by default. With `save_as_file: true`:

| Scope | Directory under the app's Documents |
|---|---|
| `host` (default) | `AppAgentScreenshots` |
| `appagent` or `all` | `AppAgent/diagnostics/screenshots` |

SDK/all artifacts remain protected from later host-only `app_sandbox_file`
calls. The normal `AppAgent/files` workspace and host screenshots remain usable.
Saving a screenshot is a mutation; an inline screenshot is a read.

Limited scopes reject mixed-ownership subtrees and backdrop effects rather than
return potentially mixed pixels. Choose an isolated subtree. Even `all` captures
one target, not a composite of every window.

See [Tools](Tools.md#host-inspection-boundary) for scene binding, custom provider
responsibilities, storage restrictions and the in-process boundary limitations.
