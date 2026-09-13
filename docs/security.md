# Security boundary

`workspace` never accepts filesystem paths or exposes native grant material. A
`WorkspaceEntryRef` serializes only a version, workspace identity, and
adapter-issued stable ID. Provider document IDs and relative native lineage
remain in app-private adapter storage. Native adapters resolve the stable ID
and revalidate it beneath the selected root on every operation. Display paths
are presentation metadata only.

The host application owns durable grant storage. Its opaque vault envelope is
the canonical operation authority: native code accepts only the versioned,
platform-tagged envelope that binds a generation, opaque root ID, normalized
root digest, and the private bookmark or tree credential. The envelope is
opaque to Dart and must never enter logs, UI models, exceptions, or analytics.
Native private stores retain only the matching root binding and entry lineage;
they do not become a fallback source of authority. A missing, stale, or
mismatched envelope/store half fails closed as `permissionLost`; recover by
re-selecting the directory rather than refreshing a credential in place.

Android additionally journals permission acquisition before taking a
persistable grant so a restart can release an orphan. It releases a
plugin-owned grant only after the last logical workspace lease is forgotten.

Successful reads always identify the exact returned slice with SHA-256.
Whole-content and platform revision evidence are distinct types. Native
adapters currently return `unverified` with absent revision evidence rather
than treating timestamp, size, or a range digest as immutable content proof.
