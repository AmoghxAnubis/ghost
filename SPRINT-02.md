# Ghost: what grew since last time?

Second sprint: opt-in local source snapshots and a read-only comparison with live measurements. Implementation is complete; final validation results are recorded below.

## Product outcome

```bash
bash ghost.sh snapshot
# Later, after using the machine:
bash ghost.sh changes
```

Ghost explains which known locations grew or shrank, orders each group by allocated bytes, and gives an inspection command for each changed source. Saving another snapshot deliberately advances the baseline; `changes` never does. Old snapshot IDs remain usable.

## Scope and decisions

- Share the seven known locations with diagnosis through one source catalog.
- Keep the existing bounded Downloads scope: aggregate top-level regular files larger than 10 MiB, deduplicating hard links by device/inode. No individual filenames persist.
- Record timestamp, measurement policy, source path, status, device identity, and allocated bytes in private NUL-delimited records. No external packages, accounts, network calls, or telemetry.
- Store history under `${XDG_STATE_HOME:-$HOME/.local/state}/ghost`, with private ownership/permissions, complete record publication, and an atomic latest-baseline pointer. Retain old snapshots without automatic pruning.
- Exclude history from its own measurements, including paths containing glob characters and newlines. Reject malformed records rather than evaluating saved data as shell code.
- Compare successful measurements only. A missing source is not zero. A new source is not measured growth. Optional sources absent in both scans are ordinary absent sources.
- Refuse mismatched home/scope comparisons and mark changed source filesystems as not comparable.
- Keep increases/decreases separate. Overlapping locations are never added into a total; a decrease is not proof of cleanup or recovered space.
- Keep default diagnosis opt-in with respect to persistence: only `snapshot` saves a baseline. `changes` uses temporary scratch space but never writes history.

Snapshots measure sources sequentially; they are not filesystem-wide atomic snapshots. Existing files may change during measurement. Failed measurements remain unavailable, and explicitly saved partial snapshots carry that status and return 2.

## Verification

The fixture suite exercises first use, multiple baselines, explicit older IDs, numeric ranking, measured growth/shrinkage, private files, no filename retention, no history feedback, source failures, missing sources, scope/device changes, corrupt snapshots, publication failure, safe path display, and unchanged application/download contents. Linux-only checks cover real sparse files, hard links, symlinks, and unreadable sources. Both suites are included in the Linux CI workflow.

Verified implementation commit: `f7bc3d5`.

- All five Bash syntax checks passed.
- Git Bash: 54 diagnosis/regression checks and 59 history checks passed (113 total). Native filesystem checks were explicitly skipped on this host.
- [Linux CI](https://github.com/AmoghxAnubis/ghost/actions/runs/38951154304): 57 diagnosis/regression checks and 65 history checks passed (122 total), as a non-root user, with no native checks skipped.
- Linux verified private directory/file/pointer permissions, refusal of publicly readable snapshots, real sparse files, hard-link deduplication, symlinked-source protection, and unreadable sources.
- Existing command behavior and read-only diagnosis passed regression checks. The new route checks also verify snapshot/changes dispatch.

This completes the sprint's implementation and validation scope. The first history CI run caught a dispatch-test assumption about extra arguments; the test was corrected to invoke `snapshot` with its actual argument contract, and the corrected implementation passed the full Linux workflow above.

## Later

Broader SDK/package-manager discovery, automatic scheduled recording, history retention controls, charts, cleanup execution, and Docker-native resource accounting remain outside this sprint.
