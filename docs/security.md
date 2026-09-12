# Security boundary

`workspace` never accepts filesystem paths or exposes native grant material. A
`WorkspaceEntryRef` is opaque and bound to its `WorkspaceId`; an adapter must
revalidate it beneath the selected root on every operation. Display paths are
only presentation metadata.

The host application owns durable grant storage. Native bookmarks and tree URIs
must stay inside its private vault and must never be placed in logs, UI models,
exceptions, or analytics. This initial pure-Dart package includes no picker,
native grant storage, or platform adapter.
