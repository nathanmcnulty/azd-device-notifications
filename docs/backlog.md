# Backlog: nathanmcnulty/azd-device-notifications

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-device-notifications
- **Source revision:** `f94a89dcf81fd1208bef4f7903d908489ec359e8`
- **Captured:** 2026-10-04
- **Items:** 5

## DEVICE-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Plans and implementation evidence are spread across files; the captured source can change while other tasks work.

**Scope:**

- docs/backlog.json
- docs/backlog.md
- Existing roadmap, execution status, open issues and pull requests &lpar;read-only&rpar;

**Acceptance:**

- Classify each candidate as implemented, still open, superseded or awaiting evidence; retain source links and reasons.
- Inspect dirty state, remotes, worktrees and local environment presence without reading secrets; avoid duplicate work with active owners.
- Resolve the actual offline validation commands and record exact current default-branch/working-tree provenance; do not copy historical live passes to newer code.

**Validation:**

- git status --short
- git remote -v
- git worktree list --porcelain
- Read the applicable instructions and validation workflow; read gh issue list and gh pr list for the named repository using nathanmcnulty. Do not create or modify issues/PRs.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md
- https&colon;//github.com/nathanmcnulty/azd-device-notifications/pull/32
- https&colon;//github.com/nathanmcnulty/azd-device-notifications/pull/31
- https&colon;//github.com/nathanmcnulty/azd-device-notifications/issues/33
- https&colon;//github.com/nathanmcnulty/azd-device-notifications/pull/37
- https&colon;//github.com/nathanmcnulty/azd-device-notifications/issues/34
- https&colon;//github.com/nathanmcnulty/azd-device-notifications/pull/35

**Evidence:**

- Current-main reconciliation used exact revision f94a89dcf81fd1208bef4f7903d908489ec359e8. DEVICE-002 remains proposed pending recipient-route and Teams lifecycle acceptance; DEVICE-003 remains proposed pending the cross-solution taxonomy comparison; DEVICE-004 is complete from the reviewed component packet; DEVICE-005 is resolved by merged PR &num;37.
- Read-only GitHub reconciliation on 2026-10-04 found issues &num;33 and &num;34 closed by merged PRs &num;37 and &num;35 respectively. Dependency PRs &num;32 and &num;36 remain open and PR &num;31 is closed; no dependency or source change was imported by this packet.
- The canonical permission-tracking checkout and its local .azure state were left untouched and no environment values were read. The owned worktree started clean from current origin/main; the reconciled packet passed 104/104 Pester, 113/113 Vitest, typecheck, build, bundle, production audit, Bicep, metadata and documentation checks.

**Review and authorization note:**

Review DEVICE-001 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## DEVICE-005: Preserve ambiguous provider-send outcomes rather than automatically duplicating delivery

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Open report captured 2026-10-03 during execution reconciliation. Another code-quality task may own an active fix; inspect its PR and current source before dispatch.

**Scope:**

- Linked issue and current source &lpar;read-only&rpar;
- Repository-local backlog evidence

**Acceptance:**

- Read the linked issue and current default branch; classify the exact defect, current owner and evidence gap.
- Record a current PR or verified resolution before selecting any implementation; preserve broader feature and live acceptance gates.

**Validation:**

- Read current issue and PR state using nathanmcnulty; do not modify or close issues during reconciliation.
- Inspect dirty state and worktrees; resolve the exact current revision and relevant offline commands before implementation.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-device-notifications/issues/33
- https&colon;//github.com/nathanmcnulty/azd-device-notifications/pull/37

**Evidence:**

- Issue &num;33 closed on 2026-10-03 through merged PR &num;37 at exact current-main commit f94a89dcf81fd1208bef4f7903d908489ec359e8.
- Current-source regressions retain accepted-but-unconfirmed sends for operator review without a second send, map aged or in-flight reservations to reviewRequired, and prevent repeat Graph POSTs after ambiguous network failures. The reconciliation run passed all 113 current Vitest tests and 104 Pester tests.
- This classification records the verified source resolution only. No provider call, recipient-visible delivery, Azure operation or live ambiguity-reconciliation acceptance was performed.

**Review and authorization note:**

Review DEVICE-005 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## DEVICE-004: Adopt reviewed deployment-validation 1.1.1

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

At initial capture the lock recorded deployment-validation 1.0.0; this packet adopts the compatible signed 1.1.1 release.

**Scope:**

- azd-components.lock.json
- scripts/vendor/Azd.DeploymentValidation/
- tests/
- docs/

**Acceptance:**

- Review the exact 1.0.0-to-1.1.1 diff and current consumer hashes before deciding to adopt.
- Prepare only the compatible managed files and lock in one owned worktree; retain domain validation extensions.
- Offline validation and commit-only rollback are required; live deployment and publication are separately authorized.

**Validation:**

- From the solution root run ./scripts/Test-Repository.ps1
- Run focused tests for changed behavior from tests/; fixtures do not prove live-service or endpoint behavior.
- After separate authorization, retain redacted exact-target live evidence and cleanup results outside public Git. Do not execute live operations from this backlog alone.

**Dependencies:**

- _none_

**Components:**

- deployment-validation

**Sources:**

- azd-components.lock.json

**Evidence:**

- Independent frozen-file review passed five source files at fresh-main base ccb4360f87bcfcdd3d05227acf976ef920054323; tracked diff SHA256 39c131105ef49fbd94abf40a1c3a23169985bc627f76441dc01de94cdee57ecd. Managed bytes match signed source revision 0c96cc89c554ffc3b3ca82ceda12da6591e816c1.
- Full offline Test-Repository in the reviewed fresh-main worktree passed 104/104 Pester and 109/109 Vitest, typecheck, build, bundle, Bicep, metadata and docs checks; npm audit reported zero vulnerabilities. Focused deployment tests passed 10/10 and were independently rerun 10/10 with provider/delivery sentinels. All five managed component files were current and exact; PSScriptAnalyzer reported zero errors.
- Notification contracts 1.0.0, domain adapter and unbound schema 1.0 plan output remain unchanged; one focused assertion makes schema compatibility explicit. Reviewed lock values and exact managed bytes were integrated after clean-path/base checks, preserving the canonical permission branch and unrelated package state. No Azure, authentication, delivery or permission operation was needed; release and optional evidence-binding adoption remain separate gates.
- Reconciled the same reviewed component and schema 1.0 assertion onto current main f94a89dcf81fd1208bef4f7903d908489ec359e8 without changing its send-ambiguity implementation. Focused deployment validation passed 10/10; the final current-main packet passed 104/104 Pester and 113/113 Vitest plus typecheck, build, bundle, production audit, Bicep, metadata and documentation checks.

**Review and authorization note:**

Review DEVICE-004 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## DEVICE-003: Compare retry/ambiguity taxonomy with authentication notifications

- **Kind:** discovery
- **Priority:** P2
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Two personal bot consumers can converge on contracts while retaining route and event logic.

**Scope:**

- src/
- tests/
- docs/
- azd-components.lock.json

**Acceptance:**

- Compare accepted, received, retryable and ambiguous results with immutable per-recipient identities.
- Fixtures cover propagation, duplicate events, foreign conversations and lost provider responses.
- Record extraction prerequisites; no shared bot runtime until both consumers have real delivery/lifecycle proof.

**Validation:**

- From the solution root run ./scripts/Test-Repository.ps1
- Run focused tests for changed behavior from tests/; fixtures do not prove live-service or endpoint behavior.

**Dependencies:**

- _none_

**Components:**

- notification-contracts
- deployment-validation

**Sources:**

- README.md
- docs/notification-taxonomy.md
- https&colon;//github.com/nathanmcnulty/azd-auth-notifications/tree/016a9ded4b9777c95a975b271fb678a8d84ef615
- https&colon;//github.com/nathanmcnulty/azd-reference/tree/8f8a41fcb3539bdc632b58cad84b668204628b79

**Evidence:**

- Compared device-notifications bbc8984d92ecbb11049645963f10fe3706461fe9 with auth-notifications 016a9ded4b9777c95a975b271fb678a8d84ef615 using exact source reads. The shared notification-contracts schemas are unchanged at azd-reference 8f8a41fcb3539bdc632b58cad84b668204628b79, so the existing bc2cf2aad4ff5ebadabe8fd0f0efcf71d94d0e0f component pin remains unchanged.
- docs/notification-taxonomy.md compares Device delivery results with Auth accepted/review/suppressed state and converter semantics. It records provider acceptance versus recipient observation, Auth gaps in normalized duplicate/destination/retry/state-recovery classifications, and the difference between Auth per-recipient identity and Device route-scoped fan-out identity.
- Device fixtures cover duplicate events, foreign-owner conversation lookup/deletion, lost provider responses, and production wait-function propagation with pending, wrong-version, exact-published and bounded-timeout responses. Auth duplicate/lost-response fixtures are identified at its exact revision; executable Auth app-propagation and conversation-isolation fixtures are missing and recorded as extraction gaps. Fixture and source inspection do not prove live delivery, tenant isolation, Teams propagation or recipient receipt.
- Shared bot extraction remains gated on per-recipient privacy-preserving identity plus real delivery and personal-installation lifecycle proof in both consumers; DEVICE-002 and AUTH-002 remain the external-delivery gates.
- Offline validation of the selected source passed 106 Pester tests, 114 Vitest tests, typecheck, build, bundle, production audit, pinned Bicep 0.46.1, metadata and documentation gates via ./scripts/Test-Repository.ps1. Propagation test doubles are local to their fixtures; Start-Sleep remains the system cmdlet afterward. No runtime or component lock changed, no messages or lab resources were created, and no live cleanup was needed.

**Review and authorization note:**

Review DEVICE-003 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## DEVICE-002: Qualify each recipient route and Teams app lifecycle

- **Kind:** verification
- **Priority:** P1
- **Status:** proposed
- **Wave:** 2
- **Authorization:** external-delivery
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Published artifacts and synthetic checks do not prove personal delivery or removal safety.

**Scope:**

- docs/
- tests/TeamsAppLifecycle.Tests.ps1

**Acceptance:**

- Capture human-visible receipts for enabled personal Teams and webhook routes on a named pilot.
- Reconcile release wording against actual release assets and current-source evidence.
- Verify same-ID catalog propagation, tenant-bound conversation capture and exact owned installation removal.

**Validation:**

- From the solution root run ./scripts/Test-Repository.ps1
- Run focused tests for changed behavior from tests/; fixtures do not prove live-service or endpoint behavior.
- After separate authorization, retain redacted exact-target live evidence and cleanup results outside public Git. Do not execute live operations from this backlog alone.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md

**Evidence:**

- _none_

**Review and authorization note:**

Review DEVICE-002 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
