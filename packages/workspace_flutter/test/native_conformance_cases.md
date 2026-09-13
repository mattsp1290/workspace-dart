# Native conformance cases

This matrix is the shared protocol-v1 checklist for the Android and iOS
engines. Native test targets must reference each applicable ID; integration
fixtures exercise the channel wiring separately. Test fixture values must never
be included in assertion output.

| ID | Input / condition | Expected terminal result | Cleanup assertion |
| --- | --- | --- | --- |
| P01 | Unknown protocol version or method | `invalidRequest` / not implemented | no operation retained |
| P02 | Missing, wrong-type, or over-limit field | `invalidRequest` | no provider work |
| P03 | Malformed cancellation envelope / unknown native response enum | `invalidRequest` / Dart fails closed as `providerFailure` | no operation retained / n/a |
| P04 | Malformed, raw, or wrong-platform tagged restore envelope through registered plugin | `invalidRequest` | no root or entry record created |
| P05 | Unknown request field through registered plugin | `invalidRequest` | no provider work |
| P06 | Unknown `cancelWorkspace` request field through registered plugin | `invalidRequest` | no cancellation or cursor cleanup side effect |
| A01 | Malformed envelope or unknown entry ID | `invalidReference` | no provider handle |
| A02 | Cross-workspace, stale, forged, or escaped lineage | `invalidReference`, or escaped symlink omitted from listing | no provider handle |
| A03 | Revoked root / moved/deleted provider entry / file-to-directory mutation | `permissionLost`, `notFound`, or `unsupported` | scopes and descriptors balanced |
| L01 | Empty and nested directory; repeated root restoration across reconstructed stores | complete page / stable root and child IDs | no live cursor for terminal page |
| L02 | Exact caps and first-entry overflow | complete or `budgetExceeded` | no unbounded allocation |
| L03 | Snapshot overflow | `unsupported` | enumerator/cursor closed |
| L04 | Cursor resume, replay, mismatch, expiry, close | page / `invalidCursor` | cursor single-use and deleted |
| R01 | Zero, exact, short, and past-EOF range | bounded read | handle closed |
| R02 | Large offset, directory file ID, non-seekable source | `invalidRequest` / `unsupported` | handle closed |
| P08 | Cyclic, malformed, or root-mismatched private lineage | `invalidReference` | no provider work |
| P11 | Provider-resource cleanup: non-seekable range positioning, null query/descriptor, and scope acquisition | bounded read / `unsupported` / `permissionLost` / `unavailable` | streams, descriptors, and started security scopes closed exactly once |
| R03 | Expected revision and partial provider failure | unverified read / typed failure | handle closed |
| C01 | Cancellation before body terminal; cancellation after captured body terminal | `cancelled` exactly once; captured body terminal unchanged | operations reach zero |
| C02 | Deadline expiry and duplicate operation ID | `budgetExceeded` / `invalidRequest` | operations reach zero |
| C03 | Concurrent workspaces, close-before-body, forget, reconciliation, detach after capture | isolated typed result; `closed` before body; detach fences delivery | close waits for matching cleanup |
| S01 | Seeded URI/bookmark/lineage/content marker | absent from errors and stringification | n/a |

Automated coverage includes Dart facade checks; Kotlin and Swift protocol and
lineage suites; Kotlin non-seekable positioning tests; fixture-free production
builds; a linked production-plugin XCTest host; a controlled iOS local-root
XCTest that drives the production handler through A01/A02, L01, R01/R02/R03,
snapshot overflow (L03), and scope balancing; the Swift bookmark suite covers
A03 stale-bookmark rejection without a scope acquisition; the iOS XCTest host
also verifies S01 public errors omit fixture/path markers and details;
and registered production-handler P01–P06 smoke tests on Android and the iOS
simulator. The iOS `nativeTest` scheme additionally runs L01/R01 through that
registered handler and verifies single-use cursor resume/replay and expiry rejection
(L04), first-entry budget overflow (L02), post-close access rejection (C03),
and A03 permission-lost/not-found failures, with its fixture compiled only
under `WORKSPACE_NATIVE_TEST_FIXTURE`.
Kotlin and Swift engine/registry suites additionally prove first-terminal
arbitration (cancel/close cannot rewrite a captured provider terminal) and detach generation-fencing:
late callbacks cannot reply and a replacement engine can run. The linked iOS
XCTest host also holds a live plugin operation through detach, asserts scope
cleanup and reply fencing, then invokes a replacement plugin. Both registered
fixtures exercise A01 never-issued IDs; A02 cross-workspace and root-swap
rejection; C01 list/read cancellation; C02 duplicate-operation and deadline terminals;
R01 exact/short/past-EOF reads; R02 directory-as-file rejection; R03 structured expected revision with
unverified output; L04 replay, cap-mismatch, and expiry
rejection; plus C03 close isolation,
close, abandon, forget, and reconciliation invalidation. Android
and iOS fixtures also issue concurrent lists for one workspace and assert every
result reuses the same opaque lineage IDs (L01). Android
instrumentation additionally exercises the production
content-resolver provider against a controlled `DocumentsProvider`; its
registered Android fixture covers L02/L04 and maps A03
permission-lost/not-found/unavailable/provider-failure terminals. The iOS
registered fixture covers the same A03 terminal vocabulary.
Kotlin JVM resolver-seam tests also verify null cursor and null descriptor
responses fail closed at the provider boundary without leaving query/read
leases; the channel handler maps the resulting unavailable read outcome.
The linked iOS XCTest host additionally verifies an external-target symlink is
omitted and that explicit deletion and file-to-directory mutation after listing
are revalidated before read. It also reconstructs the plugin with a fresh
store/provider and reopens a saved child ID without relisting, and drives a
cooperative deadline beyond `remainingMillis` before the next native check.
The Android registered nativeTest fixture verifies the same post-list
`notFound` and `unsupported` terminals.
Provider-fault and lifecycle rows are covered by the native and
registered-handler suites above; these synthetic fixtures do not qualify
physical providers or devices.
