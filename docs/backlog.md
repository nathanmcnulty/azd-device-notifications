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
- **Status:** proposed
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

**Evidence:**

- _none_

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
