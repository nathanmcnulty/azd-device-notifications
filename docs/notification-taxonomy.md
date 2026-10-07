# Notification taxonomy comparison

This is the DEVICE-003 discovery record. The comparison uses the exact source
revisions below so that a stale checkout cannot silently change the result:

| Consumer or standard | Revision | Scope used |
| --- | --- | --- |
| device-notifications | `bbc8984d92ecbb11049645963f10fe3706461fe9` | Current branch source and tests |
| auth-notifications | `016a9ded4b9777c95a975b271fb678a8d84ef615` | `git show` of `src/core.ts`, `src/contracts.ts`, `src/engine.ts`, `src/state.ts`, and focused tests |
| azd-reference | `8f8a41fcb3539bdc632b58cad84b668204628b79` | Current `notification-contracts` schemas and component standard |

The reference revision has no notification-contracts file changes after the
consumer lock's `bc2cf2aad4ff5ebadabe8fd0f0efcf71d94d0e0f` component revision.
The device lock therefore remains unchanged: this work records a comparison
and does not adopt a new shared component.

## Outcome taxonomy

Both consumers distinguish provider acceptance from recipient observation.
Their internal state and result taxonomies differ at the boundaries below.

| Boundary | device-notifications | auth-notifications | Retry or review rule |
| --- | --- | --- | --- |
| Accepted by the provider and terminal state written | `succeeded`, attempt `1` | `accepted` state, mapped to `succeeded`, attempt `1` | The route is complete for idempotency. Neither consumer claims human receipt. |
| Previously accepted | `alreadyDelivered`, attempt `0` | Terminal `accepted` row is retained; collection deduplicates the existing row without emitting another result. The result converter always uses attempt `1`. | No repeated provider send; the normalized duplicate-result mapping is a gap. |
| Active duplicate or concurrent reservation | `skipped` with `concurrentDelivery`, attempt `0` | Dispatch claims `pending` as `sending` with an ETag; a competing claim fails with HTTP 412 and produces no delivery result. | Preserve reservation concurrency; auth has no equivalent normalized skipped result. |
| Destination unavailable before send | `failed` with `destinationUnavailable`, non-retryable | No destination-unavailable classification. `suppressed` means previously queued work is no longer eligible and maps to `skipped`; dispatch exceptions map to `review`, `unknown`, non-retryable. | Destination and eligibility classifications need a shared mapping before extraction. |
| Retryable pre-send or provider failure | `failed` with `timeout`, `throttled`, `transientProvider`, or safe `unknown` and `retryable: true` | Dispatch errors map to `review`, `unknown`, non-retryable; there is no equivalent typed retry taxonomy. | A retry needs an explicit, bounded operation policy. The result contract does not schedule retries. |
| Provider response or transport failure after the send boundary | `failed` with `unknown`, `retryable: false`, code `AmbiguousDeliveryOutcome`; the durable row remains for review | A successful failure-state write retains `review` with an unknown, non-retryable result. Dispatch enumerates only `pending` rows, so review rows are not automatically resent. | Resolve provider evidence before deliberate replay; state-write failures have the separate gap below. |
| State cleanup or terminal-write failure | Pre-send release failure maps to `failed`, `unknown`, `retryable: true`, code `DeliveryStateReleaseFailed` | No corresponding release operation. A state-write failure can leave `pending` or `sending`; the review API operates on `review` rows, so stranded sending-state recovery is a gap. | Preserve concurrency tokens and define recovery for uncertain state before sharing a runtime. |

Neither runtime taxonomy has a recipient-received status. A successful Graph
or Bot Framework response proves provider processing or acceptance only.
Human-visible delivery needs a separately retained recipient observation.

## Immutable recipient identity

The auth consumer binds each delivery to `registration.id`, channel, and the
recipient object ID. Its state row is partitioned by tenant and keyed by a
hash of that delivery key; its contract route ID also includes a short hash of
the recipient. Two recipients therefore cannot share an accepted, pending, or
review row even when they receive the same event and channel.

The device consumer currently binds history to the tenant, normalized event
type, event ID, and a fixed contract route ID. The owner object ID is used to
look up the Teams conversation, but it is not included in the contract route
or delivery-result identity. An administrator email route can fan out to
multiple configured addresses through one provider request and one history
row. This represents one fan-out operation rather than independent recipient
results; it does not prove per-recipient deduplication or acceptance.

This difference is an extraction prerequisite. A future shared bot host must
carry a privacy-preserving recipient identity (for example, a stable hash in
the route key) through reservation, result, review, and lifecycle state, while
keeping raw recipients out of the shared delivery-result schema. Do not extract
or share the bot runtime until both consumers have real recipient-visible
delivery and personal-installation lifecycle proof. DEVICE-002 remains the
device consumer's external-delivery gate, and AUTH-002 remains the auth
consumer's corresponding gate.

## Boundary fixtures

The current fixtures establish the four discovery boundaries without claiming
live service behavior:

| Boundary | Device fixture | Auth comparison fixture | What it proves |
| --- | --- | --- | --- |
| Propagation | `tests/TeamsAppLifecycle.Tests.ps1` executes production `Wait-CatalogDefinition` with pending, wrong-version, exact published, and terminal timeout responses; remaining lifecycle assertions inspect script text | No corresponding executable app/installation propagation fixture at the cited revision; installation logic is source inspection only | The device fixture proves exact-version selection and bounded failure after 18 attempts. Auth fixture coverage remains a gap; neither proves tenant propagation or receipt. |
| Duplicate events | `tests/pollers.test.ts` (`suppresses a duplicate normalized event`) and `tests/delivery.test.ts` (`emits succeeded then already-delivered results`) | `tests/engine.test.ts` (`overlap and restart preserve deduplication...`) | Overlap and repeated delivery observations do not create a second provider send. |
| Foreign conversations | `tests/repositories.test.ts` (`keeps a foreign owner's conversation from satisfying the target lookup`) executes repository put/get/delete with separate owner identities; lifecycle text assertions separately inspect workload/tenant/target guards | `src/state.ts` hashes/lowercases recipient identity and partitions by tenant; `tests/state.test.ts` has no conversation-isolation fixture | Device lookup/deletion isolation is fixture-proven. Auth identity binding is source inspection with a missing executable fixture; neither proves live tenant isolation. |
| Lost provider response | `tests/delivery.test.ts` ambiguous Teams/Graph failures and `tests/graph.test.ts` (`does not resend a Graph POST after an ambiguous network error`) | `tests/engine.test.ts` (`ambiguous send is retained for review, never automatically resent`) | A possible provider acceptance is retained for operator review and is not automatically duplicated. |

These are static and synthetic fixtures. They do not establish provider
delivery, endpoint state, Teams policy propagation, or a human-visible receipt.
