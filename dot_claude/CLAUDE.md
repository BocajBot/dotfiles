# CLAUDE.md

## Project Context
Primary language: ...
Package manager: ...
Test command: ...
Lint command: ...
Entry point: ...
Generated dirs (never read): node_modules, dist, .venv, __pycache__, ...

## Working Style
- Orient once per session: `git status --short`, then targeted `rg` searches.
  Don't re-list directory structure you've already seen.
- Prefer `rg -n` and `sed -n 'START,ENDp'` over cat-ing whole files.
- Batch related searches/reads in one step; don't narrate each command.
- Smallest correct change. No drive-by refactors, renames, or formatting.
- Reuse the nearest existing pattern before inventing an abstraction.

## Testing
- Run the narrowest relevant test first; full suite only for shared
  infrastructure or final validation.
- Never weaken assertions or hide failures to make tests pass.
- Validation must match the change: config changes → verify loading;
  routing → verify dispatch; not just unit tests.

## Communication
- Report material findings, decisions, and validation results only.
- Final response: Implemented / Validated / Notes. Distinguish tested
  from inferred. Don't claim untested things work.

## Never
- Destructive commands (rm -rf, reset --hard, force push) without explicit approval.
- Print secrets or credentials.
- Fabricate test results.
