# Ghost: a first diagnosis you can trust

One developer, 60-minute scope. Implementation and the sprint's native Linux validation are complete.

Implemented in `ghost.sh` and `lib/diagnosis.sh`, with a README, fixture suite, LF checkout rules, and a Linux CI workflow. All three Bash syntax checks and 52 behavioral checks pass in Git Bash. The [Linux workflow for commit 6f0445d](https://github.com/AmoghxAnubis/ghost/actions/runs/38946194864) also passed all syntax checks and 55 behavioral checks as a non-root user, including native symlink and permission checks with a real sparse-file fixture. The initial test-fixture allocation assumption is corrected and verified. This completes the sprint's validation gate; the broader v1 roadmap remains separate.

## Product contract

Ghost tells Linux developers, power users, and students where their storage went, why it is there, and what deserves investigation before cleanup.

**Ghost investigates aggressively. Ghost cleans conservatively.**

Keep the Bash CLI, local processing, Ghost identity, actual-versus-logical size distinction, and evidence-first approach. No accounts, network calls, telemetry, AI API, or platform expansion.

The sprint ships the first part of the context/reclaimability engine: a useful diagnosis with explainable review priorities. It does not ship the complete v1 journey or cleanup execution.

## Evidence from the repository before this sprint

Reviewed both scripts and the available Git history. The current `ghost.sh` identifies itself as v0.8 and contains 1,283 lines. It implements all seven investigation commands described in the product brief.

| Finding | Code evidence | Product consequence |
| --- | --- | --- |
| No-argument invocation opens help | `ghost.sh:1225` | The first encounter presents a command menu before answering the user's question. |
| Diagnosis is organized into long sections and fixed priorities | `analyze`, `ghost.sh:931` | The user must decide what matters and what command to run next. |
| Downloads receives HIGH reclaimability as a whole | `ghost.sh:989` | Valuable personal files can appear reclaimable without sufficient context. |
| Entire `.npm` is treated as package-manager cache | `ghost.sh:870`, `ghost.sh:920` | The label is broader than the evidence. |
| Docker is inferred from the size of `~/.docker` | `ghost.sh:976` | A directory measurement is presented as Docker resource knowledge. |
| Age summary performs six separate traversals, then another for display | `ghost.sh:728`, `ghost.sh:808` | First diagnosis would inherit avoidable work if it simply calls every investigator. |
| Most scan errors are discarded | `2>/dev/null` in discovery helpers | Unreadable data can look like an empty result. |
| Duplicate recovery sums logical sizes without device/inode accounting | `ghost.sh:523` | Hard links and sparse files can make apparent recovery differ from disk space actually released. |

Good foundations to preserve: duplicate detection groups by size before hashing, confirms matching contents with `cmp`, and uses NUL-delimited candidate paths. Age analysis already states that age is evidence rather than a deletion decision. Large-file output already distinguishes actual and logical size.

Validation completed during this review: Git Bash syntax check and the existing `help` command passed. Linux behavior, Docker integration, and recovery estimates have not been runtime-validated here.

## Sprint outcome

Running `./ghost.sh` or `./ghost.sh analyze` should answer, near the top of the output:

1. How much pressure is this filesystem under?
2. Which measured findings should I investigate first?
3. Why did Ghost choose them, and what read-only command takes me deeper?

Use `analyze` as the existing entry point. Do not add another competing diagnosis command. The installed `ghost` executable belongs to a later packaging sprint.

## Exact scope

Build a small finding record inside Bash: path, allocated bytes, optional logical bytes, evidence, classification, reason, and next investigation command. Prefer a few explicit functions and arrays over a framework or rewrite.

Collect only enough evidence to make the first experience useful:

- Disk pressure from one `df` snapshot.
- Existing known application/cache locations, measured once per location. Show their actual scope; do not imply every byte is disposable.
- Top-level Downloads files larger than the existing 10 MiB threshold, with modification age and installer/archive type. Keep this pass NUL-delimited. State that nested Downloads are outside this quick diagnosis.

Do not automatically hash the home directory or run every existing investigator. Keep `scan`, `large`, `ghosts`, `inspect`, `duplicates`, and `age` available for deliberate deeper investigation.

Apply rules in this order:

| Rule | Classification | Explanation |
| --- | --- | --- |
| Known personal/project or application-managed data | PROTECTED | Importance or ownership takes precedence over age, size, extension, or duplicate status. No cleanup recommendation. |
| Old installer/archive in the scoped Downloads pass | REVIEW | File type, location, size, and modification age justify review; they do not establish that it is unused. |
| Recognized cache location without verified cleanup semantics | REVIEW | Likely generated data, but the owning application's state and cleanup method have not been checked. |
| Unknown or conflicting evidence | PROTECTED | Ghost cannot justify reclaimability. Explain the uncertainty. |

Keep SAFE as a reserved classification in this first engine. Emit it only once a specific application adapter can justify regeneration and a suitable cleanup method; this sprint does not need a SAFE result. A cache-looking path alone is insufficient.

For this scoped implementation, application directories are measured as context, not recursively offered as individual cleanup candidates. Personal/project protection applies before every candidate rule. Do not claim universal project detection from a short directory-name list. If evidence is uncertain, use PROTECTED.

Prioritize the three largest successfully measured REVIEW findings by allocated bytes. This is a transparent investigation order, not a safety score. Show PROTECTED findings separately as storage context. Do not fill empty slots with imaginary or zero-byte findings.

## The 60-minute schedule

| Time | Work | Reviewable result |
| --- | --- | --- |
| 00–05 | Define the finding record and make routing callable through a small `main` function, guarded when sourced. Prepare an isolated fixture home. | The classifier can be checked without scanning a real home directory. |
| 05–20 | Implement classification and the bounded collectors above. Reuse existing path and size helpers where correct; measure a source once. | Evidence becomes REVIEW or PROTECTED with a concrete reason. |
| 20–35 | Make no arguments invoke the improved `analyze`. Render disk pressure, top three review findings, reasons, exact paths, and shell-quoted read-only drill-down commands. Keep explicit `help`. | One command produces a useful first diagnosis. |
| 35–45 | Tighten measurement and failure behavior in this new flow. Distinguish allocated/logical bytes, reserve SAFE, label `.docker` as directory-only evidence, and report incomplete scans. | The diagnosis communicates what was measured and what remains unknown. |
| 45–55 | Run syntax checks and fixture-based behavioral checks below. Fix failures before expanding scope. | Demonstrable classification, ranking, and non-destructive behavior. |
| 55–60 | Write a short README covering Linux/Bash requirements, first command, investigation commands, classification meanings, and current limits. | Another Linux user can try the product without this conversation. |

If behind at minute 35, cut presentation polish and the number of recognized cache locations. Keep classification, honest measurements, next steps, and verification. Do not borrow the verification window for new features.

## Output target

Illustrative fixture output, not measurements from the user's machine:

```text
GHOST — Disk Space Investigator
Storage pressure: HIGH · 88% used · 12 GiB available
Scope: known application locations + top-level Downloads (>10 MiB)

START HERE
1. REVIEW  ~/Downloads/linux-image.iso
   1.5 GiB on disk · installer/archive · modified 392 days ago
   Why: large, old download; Ghost cannot tell whether you still need it.
   Investigate: ./ghost.sh inspect '/home/demo/Downloads'

2. REVIEW  ~/.cache/JetBrains
   820 MiB on disk · application cache location
   Why: generated-data candidate; application state has not been checked.
   Investigate: ./ghost.sh inspect '/home/demo/.cache/JetBrains'

APPLICATION CONTEXT
PROTECTED  ~/.local · application-managed data · inspect before acting

No files changed. Review candidates are not guaranteed recovery.
Deeper age evidence: ./ghost.sh age ~/Downloads
Duplicate investigation: ./ghost.sh duplicates
```

Use MiB/GiB for binary units. If fewer than three candidates exist, show fewer.

## Definition of done

- [x] No-argument invocation and `analyze` show the same diagnosis; explicit `help` remains available.
- [x] Within the first 25 output lines, a user can see disk pressure and the first finding's evidence, reason, and next step.
- [x] A fixture old archive is REVIEW; a large personal or application-owned item is PROTECTED even when old. A recent download is not called stale.
- [x] Cache locations without a verified adapter never receive an unconditional SAFE label.
- [x] Ranking uses allocated bytes; Linux sparse-file metadata is exercised on every host. A real Linux sparse-file fixture is included for native verification.
- [x] Paths containing spaces, leading dashes, or newlines survive collection and receive unambiguous display and shell quoting. The emitted inspector command is executed by the suite.
- [x] Empty sources show an honest empty state. Injected measurement/scan failures are reported as incomplete, never converted into successful zero-byte results.
- [x] No aggregate recovery number adds overlapping folders, old files, caches, or duplicates. Age labels mean time since modification, not time since last use.
- [x] Docker directory size is never described as unused images/volumes or reclaimable Docker storage.
- [x] Fixture checks confirm investigation leaves file contents and directory entries unchanged.
- [x] Bash syntax and all existing command routes receive smoke checks.
- [x] Run native symlink, sparse-file, and non-root permission checks on Linux. Verified by the successful Linux workflow for commit `6f0445d`: 55 checks passed, with no native checks skipped.

The original duplicate investigator remains available, but its estimate is outside this sprint's trusted diagnosis. Document its logical-size/hard-link limitation; do not fold it into a recovery total.

## Deliberately later

Next, carry these findings into a reviewable cleanup-plan format with exact targets, evidence, operation, expected impact, and revalidation requirements. Add Docker-native read-only evidence before Docker cleanup rules. Fix device/inode and allocated-space accounting before promising duplicate recovery.

Only then implement explicit approval, application-aware cleanup, dry-run parity, and measured before/after recovery. Local growth history can subsequently answer “what changed since last time?” using the same evidence model.

TUI polish, install/uninstall/version commands, release packaging, configurable thresholds, wider SDK/package-manager discovery, and scan-history UX stay outside this hour. The product improvement here is a complete, understandable first investigation, with a foundation that later cleanup can trust.
