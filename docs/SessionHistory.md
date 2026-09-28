# Session history and recoverable Trash

AppAgent keeps conversation history separate from general-purpose file access.
`session_manage` provides `list`, `read`, `create`, `switch`, `rename`, `archive`,
`delete`, `archived`, `restore` and `merge`, plus `models` and `set_model`.
`session_search` searches active history owned by the current agent.

## Archive and restore

`archive` moves a session into recoverable Trash. `delete` is an alias for the
same operation, never permanent deletion. Trash is not automatically emptied.

Example arguments to `session_manage`:

```json
{"op": "archive", "session_id": "<idle-session-id>"}
```

```json
{"op": "archived"}
```

```json
{"op": "restore", "session_id": "<archived-session-id>"}
```

Running, streaming and unfinished sessions cannot be archived. A tool cannot
archive the session executing it. `clear` is disabled; create a new session or
archive the old one instead.

The sidebar's “移入废纸篓” action follows the same recoverable lifecycle. The
“废纸篓” screen offers restore and permanent deletion. Permanent deletion is
human-only and requires a separate second confirmation; there is no model-facing
purge operation or parameter.

Storage must succeed before the UI removes a session or switches away from it.
Failures leave the history available and show an error. Dismissed dialogs,
duplicate confirmations and stale callbacks cannot authorize another deletion.

## Merge without a model call

```json
{
  "op": "merge",
  "source_session_ids": ["<first-id>", "<second-id>"],
  "title": "Combined discussion"
}
```

Merge requires at least two distinct owned, idle source sessions and creates a
new session in the requested source order. The source sessions remain unchanged.
The executing session cannot be a source.

Message, turn and tool-call identities are remapped while preserving tool-result
pairing, images, arguments, error flags, content blocks and turn records. This is
a history copy, not a summary: merging makes no model call. The new session uses
the current agent's identity and model policy.

`read` supports message pagination and UTF-8 byte fragments for an oversized
message. Follow the returned continuation fields rather than treating a partial
response as the complete history.

## Authorization and repository protection

Session mutations still obey read-only policy and normal operation
authorization. SDK inspection approval is not permission to purge history.

`FileSessionStorage` automatically registers both default and custom repository
locations for protection. Generic file, sandbox, download, screenshot and skill
writers cannot modify the repository or Trash, or replace an ancestor containing
them. Use the dedicated session lifecycle APIs instead.

Custom `SessionStorage` implementations must implement the recoverable lifecycle
methods to support Trash. Otherwise these operations fail as unsupported; the
SDK never falls back to destructive legacy deletion.

This is an SDK tool boundary, not an in-process security sandbox. Path protection
does not track copied data or hard links and cannot prevent another thread from
replacing a file between validation and I/O.
