# Consumer guide

Create `WorkspaceAccess` with a trusted adapter, pass an explicit budget and
cancellation token to every list/read, and switch on `WorkspaceOutcome`.
Successful reads always carry the exact returned bytes and a SHA-256 digest of
that slice. Treat `changed` and `unverified` stability as non-snapshot results.
Never turn a display path into a filesystem path or persist a page cursor.

Persist `WorkspaceEntryRef.serialize()` for a citation and reconstruct it with
`WorkspaceEntryRef.parse()`. The serialized stable ID is non-authoritative;
the adapter-private mapping and root grant must still validate on every open.
Do not persist `WorkspacePageCursor`, which is process-local.

Flutter hosts implement `WorkspaceGrantVault`, then create
`WorkspaceGrantManager`. `selectDirectory` writes pending state before the
native picker. `restore` returns `FlutterWorkspaceAccess` with its validated
root directory. Picker dismissal is the typed `cancelled` failure. Call
`WorkspaceAccess.close()` to cancel only that workspace's operations.

Treat the vault value as opaque and durable. It is bound to one native root
generation and cannot be transferred between workspaces or platforms. If
restore or later access returns `permissionLost`, discard that vault record and
ask the user to select the directory again; do not attempt to decode, edit, or
refresh its native credential in Dart.

The example's preferences vault is device-test support, not a production
secret-store recommendation. Actual-device provider conformance remains gated
by the support matrix.
