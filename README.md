# Ghost

**Understand where your Linux storage went, why it is there, and what deserves review before cleanup.**

Ghost is a privacy-first storage investigator for Linux developers, power users, and students. It runs locally in Bash, with no accounts, telemetry, cloud backend, or AI API.

**Ghost investigates aggressively. Ghost cleans conservatively.**

## Try it

Keep `ghost.sh` and its `lib/` directory together. From this checkout:

```bash
bash ghost.sh
```

The default diagnosis shows filesystem pressure, up to three review priorities ranked by allocated disk space, the evidence behind each finding, and a quoted read-only command to investigate further. `bash ghost.sh analyze` produces the same diagnosis.

Requirements: Linux, Bash **4.4+**, GNU coreutils and findutils, and awk. These provide `df`, `du`, `stat`, `realpath`, `sort`, `date`, `mktemp`, `find`, and the utilities used by the deeper investigators. Run as your normal user; root privileges are unnecessary and hide useful permission boundaries.

Ghost currently investigates and reports. It does not execute cleanup or change your files. Diagnosis uses a private temporary workspace, removed when the command exits. Ordinary filesystem access times may change when data is read.

## What the diagnosis covers

- Home filesystem pressure, measured from one `df` snapshot.
- Chrome and JetBrains cache locations under `~/.cache`, and npm's `~/.npm/_cacache` directory.
- `~/.local`, `~/.var`, and `~/.docker` as protected application storage context.
- Top-level regular files in `~/Downloads` larger than 10 MiB, including file allocation, modification age, and installer/archive extensions.

The first diagnosis is deliberately scoped. It does not hash your home directory, recurse through Downloads, inventory all SDKs or applications, or infer Docker resources from directory size. Directory measurements exclude nested filesystems and do not follow symlinks. Aliased source paths are skipped and reported; other investigators can be run explicitly for deeper evidence. A very large application directory can still take time to measure.

## How Ghost reasons

| Classification | Meaning |
| --- | --- |
| **REVIEW** | Evidence justifies investigation. Examples: a large installer/archive download modified more than 30 days ago, or a recognized cache location whose cleanup semantics are unverified. |
| **PROTECTED** | Personal, project, application-managed, recent, or unknown data. Ghost has not established reclaimability. |
| **SAFE** | Reserved for future verified, application-specific cleanup rules. The current diagnosis never emits SAFE. |

Ownership evidence takes priority over age and file type. Recognized personal/application paths and project markers (`.git`, `.hg`, `package.json`, `pyproject.toml`, `Cargo.toml`) protect findings. This is conservative evidence, not universal project detection. Unknown file types remain protected. Nested application and project contents are not offered as individual cleanup targets by the diagnosis.

Review order means **largest allocated bytes first**, not safest to remove. File age means time since modification, not time since last use. Extensions suggest a type; they do not prove a file is dispensable. Directory and file measurements may overlap, so Ghost does not combine them into a recovery promise.

## Investigate further

```bash
bash ghost.sh scan                    # Disk usage and largest home directories
bash ghost.sh large                   # Files >500 MiB; allocated vs logical size
bash ghost.sh ghosts                  # Known storage locations
bash ghost.sh inspect "$HOME/Downloads" # Directory contents, including hidden entries
bash ghost.sh age                     # Files >10 MiB, modified >30 days ago in Downloads
bash ghost.sh age /path/to/directory
bash ghost.sh duplicates              # Size grouping, SHA-256, then byte comparison
bash ghost.sh help
```

The deeper investigators predate the new diagnosis and retain limits: age/large-file output does not fully support filenames containing newlines, most legacy scans suppress some filesystem errors, and duplicate recovery is a **logical-size estimate** that does not account for hard links or sparse allocation. Duplicate confirmation does not establish whether an application needs both copies. These estimates are excluded from the new diagnosis's priorities and no recovery total is inferred.

Docker evidence currently describes only the measured `~/.docker` directory. The Docker daemon may store its data elsewhere; Ghost does not yet know which images, containers, or volumes are unused.

Diagnosis exit codes: `0` = completed within its stated scope, `1` = prerequisites/setup failed, `2` = incomplete evidence (for example, unreadable sources, aliases, or failed measurements). Successful measurements remain visible when another source fails. Missing optional directories are normal.

## Verify changes

```bash
bash -n ghost.sh
bash -n lib/diagnosis.sh
bash -n tests/diagnosis_test.sh
bash tests/diagnosis_test.sh
```

The suite creates an isolated fixture root without changing your home setting. It exercises classification, allocated-space ranking, shell quoting, read-only drill-downs, failure reporting, unchanged file contents, and existing command routes. Temporary fixtures are removed afterward. Run on Linux as a non-root user to exercise native symlinks, sparse files, and permission behavior. Git Bash can exercise the portable checks; it cannot validate Linux filesystem semantics.

The included GitHub Actions workflow runs the same checks on Linux after a push or pull request. Its native filesystem checks must pass before release.

## Next

The next product layer is a reviewable cleanup plan with exact targets, reasons, application-aware operations, and revalidation. Explicit approval, matching dry-run behavior, and measured before/after recovery come after trustworthy classification. Docker-native evidence, local growth history, installation, and TUI polish follow that foundation.

See [the sprint plan](SPRINT-01.md) for the implementation scope and acceptance criteria.
