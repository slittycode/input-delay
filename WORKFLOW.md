# WORKFLOW — commit discipline, build gates, and verification protocol

Derived from project experience: the failure mode is an agent reporting a step's
*intent* as its *completion*. These rules exist to make the pipeline mechanical
where possible.

## 1. Build gate (enforced by pre-commit hook)

A pre-commit hook at `.githooks/pre-commit` runs `swift build -c release` for
every Swift target (`latbudget`, `lagtrack`). If either fails, the commit is
blocked. This is not a suggestion — it is the gate.

To enable it:

    git config core.hooksPath .githooks

The hook uses `&&`, not agent discretion. If you bypass it with `--no-verify`,
you own the failure.

## 2. One change class per commit

Never bundle different risk classes in one commit:

| Class | Examples | Risk |
|-------|----------|------|
| **Docs-only** | FILES.md, README.md, STATUS.md | Low — no executable bytes |
| **Validated fix** | verify-all.sh sed portability, stderr routing | Low-moderate — proven before commit |
| **New feature** | --pollrate mode, new CLI flag | High — unvalidated, may compile but produce wrong results |

If a validated fix and a new feature touch the same file, split them. The build
gate ensures the split costs nothing: if both compile, two commits is two
gates, not four commands.

## 3. verify-all.sh post-change protocol

Any change to `verify-all.sh` triggers a mandatory re-run against the *committed*
bytes:

    git commit -m "fix: ..."
    ./verify-all.sh

"I tested it earlier" is not sufficient. The file changed; the verification
against those exact bytes is the guarantee, not the memory of a prior run.

## 4. --pollrate validation

`--pollrate` produces a new native raw-report number — an empirical claim that
must agree with the independent reference. Before trusting a new result:

    ./latbudget/validate-pollrate.sh

This runs `--pollrate --duration 15` over Bluetooth and asserts the measured
rate is within 60–72 Hz (matching the ~68 Hz browser + stage B BT reference).

If `--pollrate` disagrees with both independent paths on the same transport,
the mode is wrong, not the reference. Do not ship the number without resolving
the discrepancy.

## 5. FILES.md drift prevention

`FILES.md` is a static manifest of `/main/` URLs. It will drift the instant any
file is added or renamed. To regenerate:

    ./scripts/update-files-md.sh

Better: the header stamps the commit SHA it was generated at, so a reader can
tell whether it's current. If `git rev-parse HEAD` does not match the SHA in the
file's header, the manifest may be stale.

## 6. General principles

- **Mechanism, not discipline.** If a rule can be enforced by a script or hook,
  it should be. Agent memory is not a control.
- **Verify the bytes that shipped.** Testing before commit is good; testing the
  exact committed bytes is the guarantee. Re-run after commit when possible.
- **Don't bundle speculative with safe.** A compile failure in a new feature
  should never block a validated fix that's ready to ship.
