# Consumer guide

Create `WorkspaceAccess` with a trusted adapter, pass an explicit budget and
cancellation token to every list/read, and switch on `WorkspaceOutcome`.
Successful reads always carry the exact returned bytes and a SHA-256 digest of
that slice. Treat `changed` and `unverified` stability as non-snapshot results.
Never turn a display path into a filesystem path or persist a page cursor.

The memory adapter is deterministic test support only. Mobile selection,
durable vault handling, and actual-device conformance remain pending the
platform feasibility gates described in the project plan.
