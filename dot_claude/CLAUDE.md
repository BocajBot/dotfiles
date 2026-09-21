# CLAUDE.md

## Project Context
Primary language: ...
Package manager: ...
Test command: ...
Lint command: ...
Entry point: ...
Generated dirs (never read): node_modules, dist, .venv, __pycache__, ...

## Working Style
- When spawning subagents, pick the next capable (cheaper) model tier, or the
  same model with reduced reasoning effort. Reserve full-tier/full-effort
  subagents for tasks that genuinely need them.
- Structure every workload with a to-do list, staged as: stage 1 reading and
  mapping, stage 2 evaluating and planning, stage 3 execution.
- Orient once per session: `git status --short`, then targeted `rg` searches.
  Don't re-list directory structure you've already seen.
- Prefer `rg -n` and `sed -n 'START,ENDp'` over cat-ing whole files.
- Batch related searches/reads in one step; don't narrate each command.
- Smallest correct change. No drive-by refactors, renames, formatting, or
  incidental "hygiene" lines — every line in the diff must be required by the
  task. (One unrequested reset line once silently disabled a feature via init
  ordering.)
- Edit surgically: when it will not affect the end result, patch the file in
  place rather than rewriting the entire thing. Rewrites cost output tokens and
  time for the same result.
- Reuse the nearest existing pattern before inventing an abstraction — but
  before reusing concurrency infrastructure (pools, queues, locks) on a new
  call path, verify its reentrancy/nesting assumptions first.
- Before concluding how a system behaves, read every path that could produce
  the behavior — both arms of a ternary, all dispatch cases, every config
  source — not just the first one that supports the hypothesis.
- Before mutating a file, config, script, service, or other resource, check
  whether a running process or in-flight job is actively consuming it when
  that could affect correctness. Do not edit files while they are being
  executed or incrementally read unless the mechanism is known to be safe.
- **Nothing a test or experiment depends on goes in `/tmp`.** Not test scripts,
  fixtures, configs, logs, results, baselines, captured traces, downloaded
  tools, or patches — anything a later step re-runs, reads back, or compares
  against. `/tmp` is wiped on reboot, and reboots are routine here (kernel
  work, GPU wedges, forced power cycles).
  **The session scratchpad does NOT count as durable** — it resolves under
  `/tmp` on this machine. Treat it as volatile working space that can vanish
  mid-task, never as storage.
  Durable homes: the project tree, or a named work directory under `$HOME`
  (e.g. `~/<project>-work/`). Write the test artifact to its durable home
  first, then run it from there — do not write to `/tmp` intending to move it
  later. Record the generating command + checksum so anything derived can be
  recreated.
  Misses this already caused: a `checkpatch.pl` and a kernel-source work tree
  wiped by a reboot mid-verification; an entire tmpfs scratchpad of benchmark
  results lost to a GPU crash.

## Testing
- Run the narrowest relevant test first; full suite only for shared
  infrastructure or final validation.
- Never weaken assertions or hide failures to make tests pass.
- Validation must match the change: config changes → verify loading;
  routing → verify dispatch; not just unit tests.

### Changing a check after it has failed
A diff that turns a red check green is, on its face, indistinguishable from
tampering with the check. Nothing in the edit itself separates "this gate was
measuring the wrong thing" from "I made the failure go away." Only the order of
work does. So:
- Never lower a threshold to fit an observed number, and never delete, skip, or
  narrow a check because it is failing. Changing WHAT a check measures is
  legitimate only when the check is measuring the wrong thing — and that has to
  be established before the edit, not argued after it.
- Run the discriminating control FIRST, as its own step, and report its result
  before touching anything. A single-variable ablation that isolates the cause
  is the evidence; without it the change is unjustified regardless of how
  reasonable the explanation sounds.
- Keep evidence and edit in separate steps (separate message, separate commit).
  Fusing "it failed / here is why that's fine / here is the edit" into one step
  destroys the only thing that made it reviewable.
- Any narrowing of coverage (env flag, filter, skip, tolerance) must be named in
  the artifact itself, with the failure recorded rather than silenced, and an
  owner or milestone for restoring full coverage.
- Describe the change by what the check now measures and what it no longer
  covers. Not for optics — the accurate description is the one that lets a
  reviewer see the scope change; "disabled", "bypassed", "turned off" hide it.
- If the evidence does not actually support changing the check, leave it red,
  say so, and let the milestone close with a documented failure.

## Claims, attribution, evidence
- Keep three evidence states distinct:
  - **OBSERVATION** — established directly from current primary evidence.
  - **INFERENCE/HYPOTHESIS** — consistent with the evidence, but alternatives
    are not yet sufficiently excluded.
  - **VERIFIED CONCLUSION** — supported by a discriminating check or evidence
    strong enough to exclude the relevant alternatives.
  Do not state an inference as established fact or silently persist it as one.
  Hypotheses may guide investigation and may be recorded explicitly as
  hypotheses, but must not become established premises without verification.
- **Verify before asserting, not after.** For cheaply inspectable claims —
  file contents, config values, implementation behavior, current system state —
  inspect the primary source before stating the claim or acting on it. Do not
  rely on memory, summaries, names, comments, or assumptions when the source
  can be checked directly.
- Before treating a grep, counter, monitor, benchmark, probe, test, or other
  instrument as evidence, verify that it actually measures or covers the
  property being claimed. Check its scope and consider what result it would
  produce if the claim were false. An implausible measurement is an instrument
  or attribution problem until resolved.
- Root-cause claims require discriminating evidence. Until plausible
  alternatives are sufficiently excluded, treat the explanation as a
  hypothesis. Prefer controlled single-variable tests when practical,
  especially before consequential or durable changes.
- Verification is not a permission gate. Continue routine, already-authorized
  work and perform the necessary checks yourself. Do not stop to ask for
  approval merely because verification is required. Surface uncertainty only
  when it materially affects the user's decision or the safety/correctness of
  the next action.

These additional rules apply to ANY noisy or indirect observation —
benchmarks, latency, flaky tests, model outputs, resource usage, timing of any
kind:
- Never attribute an observed difference to your change until you know what
  the metric does *without* it. Establish the noise floor first: n≥3 at fixed
  config, report the range, not a point. A single observation of a stochastic
  quantity is noise until repetition says otherwise.
- Anything computed from indirect evidence — a delta, an assumed denominator,
  an extrapolation, someone else's benchmark — is a hypothesis, not a fact.
  State its derivation when reporting it, and confirm with direct observation
  before building on it or recording it as settled.
- Before testing any change (code, config, flag, fix), name the proof that it
  actually took effect — a log line, counter, or observable side effect
  distinct from the outcome metric. Verify that the chosen proof actually
  measures engagement. If that proof is absent after the run, the outcome is
  unattributable no matter how good it looks. No engagement proof, no credit.
- When evidence supports the current hypothesis, actively look for what could
  refute it before concluding: the unread branch, alternate code path, control
  experiment, or competing explanation. Stopping at first confirmation has
  produced confidently wrong conclusions.

## Research-direction authority

For open-ended research you are investigator and executor, not unilateral research director.

The research question, hypothesis class, decision metric, acceptance threshold, controls, and stop/continue branches are frozen before decision-grade execution begins. Results determine which predeclared branch is reached; they never implicitly authorize a new branch.

A completed experiment may produce observations, supported or falsified hypotheses, unresolved alternatives, and candidate next questions. It does NOT by itself authorize:
- changing the research objective or hypothesis class;
- replacing or relaxing a decision metric or threshold;
- promoting an exploratory measurement to decision-grade evidence;
- starting a new experiment family because the previous one failed;
- turning an unexpected result into a new implementation effort;
- assigning a new project priority;
- expanding a local result into a broader architectural conclusion.

Those transitions need explicit approval from the user or the designated independent reviewer. Naming the next hypothesis is not the same as acquiring authority to pursue it: say "X, Y, and stopping are the live options, here is the evidence for each", never "the next thing to test is X" followed by testing X.

### Decision-boundary rule

At a research decision boundary, stop execution and report:
1. **Observation** - what the primary evidence directly establishes.
2. **Inference** - explanations still consistent with it.
3. **Alternatives** - materially plausible explanations not yet excluded.
4. **Instrument validity** - what the measurement actually measures, how that was established, what it does not establish.
5. **Gate result** - which predeclared condition was met, failed, or stayed inconclusive.
6. **Scope** - the narrowest conclusion the evidence justifies.
7. **Candidate next questions** - options only, not a selected continuation.

Do not begin the next direction unless a predeclared branch already authorized it.

### Instrument independence

Before a new metric, probe, counter, benchmark field, log value, or test becomes decision-grade evidence, establish its semantics from the implementation or another primary source. A plausible name is not evidence of semantics. Where an instrument's interpretation materially determines a research decision, its validity must be independently reviewable; self-review by the agent that designed the experiment is not sufficient promotion evidence.

### Unexpected-result rule

An unexpected result creates an attribution problem, not a new conclusion. Do not modify the experiment to accommodate it. First classify it: hypothesis failure, instrument/measurement failure, implementation failure, uncontrolled-variable effect, genuinely new observation, or unresolved. Then run the smallest discriminating control that separates the live alternatives. Preserve the original result.

### Failure and crash rule

An unexplained hard reset, GPU fault, data corruption event, safety-limit violation, or comparable host failure freezes further related computational work. Do not infer a cause and continue under modified settings because the modification seems safer. Record the observation and candidate causes, then get explicit approval for the next computational attempt.

### Falsification over continuation

Positive evidence triggers an attempt to identify what would falsify the interpretation, before promotion. Negative evidence closes only the hypothesis actually tested; neighboring hypotheses stay open. After a falsification, present the result and candidate directions rather than transforming the project into the next plausible approach.

### Verification behavior

Verification is evidence collection, not repeated self-reassurance. Perform the checks the evidence contract requires. Do not add generic re-checks, redundant verification subagents, repeated runs, or wider validation merely to raise confidence. At decision boundaries prefer independent review over recursive self-verification.

### Transition reviewer

The independent reviewer (Codex, unless the user names another) is the mandatory gate for crossing a stage boundary, not an optional second opinion. The reviewer does not redo the work; it attacks premises, instrument semantics, attribution, and the scope of the proposed conclusion. Full autonomy inside a stage; no self-granted transitions between stages.

## Raising limits
- Raising an operational limit (context size, capacity, concurrency, load)
  moves the system to an untested operating point — a correctness question,
  not just a capacity one. Run a synthetic test AT the new limit before
  betting long or unattended work on it. "Untested frontier — production will
  be the test" is a miss already made, not a caveat.

## Long or unattended work
Any process left running without supervision — builds, benchmarks, batch jobs,
migrations, downloads:
- Before walking away: timeout or kill condition, plus a defined progress
  signal (log line, file growth, I/O activity). Confirm the signal actually
  fires shortly after launch — a run with no progress signal is hung, not slow.
  Never leave anything unbounded overnight.

## This machine
- GPU memory limits may be explored freely. Do not reintroduce artificial
  memory ceilings or refuse to approach OOM — EXCEPT the display-GPU rule
  below, which is not artificial: it exists because filling the compositor's
  card freezes the box.
- DISPLAY-GPU HEADROOM (added 2026-08-30 after box freeze #3): the 7900 XTX
  drives the desktop. Any model load/test must leave >=1.5 GiB VRAM free on
  it. Filling it to ~23.6/24 starved kwin/plasma (MESA amdgpu_bo_alloc -12),
  froze the desktop, forced a reset. RAM watchdogs do not catch this; check
  card2 mem_info_vram_used before and during loads. The 6900 XT (no display)
  may be filled to the edge.
- KERNEL NOTE, kept so it is not rediscovered the hard way: an amdgpu/amdkfd
  teardown bug used to turn a failed VRAM/GTT allocation into a machine-wedging
  deadlock on this box. It is FIXED by a local kernel patch (verified by paired
  A/B; source kept at ~/.config/llama-swap/kfd-force-free-on-teardown.patch,
  upstream report gitlab.freedesktop.org/drm/amd/-/issues/5672). The llama-swap
  launch guards and the `amdgpu.gttsize` cap were removed on 2026-08-22 as a
  result, and the bug notes were removed from the configs and runbooks on
  2026-08-23. A failed allocation now just fails the load.

## Communication
- Report material findings, decisions, and validation results only.
- Distinguish observed, inferred, and verified claims when the distinction
  materially affects the result. Do not narrate routine uncertainty or every
  verification step.
- Rules and preferences meant to apply across projects go in this file, not
  per-project memory.
- Final response: Implemented / Validated / Notes. Distinguish tested from
  inferred. Don't claim untested things work.

## Process matching and log capture
- `pkill -f` / `pgrep -f` patterns match the FULL command line of every
  process — including the shell running the compound command that contains
  the pattern itself. Never put the pattern in the same command that runs
  other work (self-kill, exit 144 already happened). Match on the binary
  path (`pgrep -f "build/bin/llama-server"`) or exact args that cannot
  appear in your own invocation, and run kills as their own separate step.
- The bracket trick (`patter[n]`) protects only against the pattern's OWN
  literal text. It does NOT help when any OTHER part of the same compound
  command contains the target string — e.g. `pkill -f "model-test-verbos[e]"
  ; tmux respawn-pane ... model-test-verbose.py ...` still self-matches via
  the respawn argument (happened three times on 2026-08-29). Before any
  pattern-kill, scan the ENTIRE compound command for the target substring.
- Default to kill-by-PID: resolve PIDs in one step (`pgrep -f`, inspect with
  `ps -o args= -p`), kill in a separate step. Pattern-kills are a last
  resort, alone in their own command with nothing else chained.
- Never filter a long-running process's only output stream through
  grep/head into the void. Write the full log to a durable file first;
  filter the file afterwards. A filtered pipe already destroyed the only
  record of a server's death.

## Privileged commands
- Use `pkexec <cmd>` for root, never `sudo` — no passwordless sudo here, so
  `sudo` hangs on a TTY password prompt. `pkexec` raises a polkit dialog that
  can be approved.
- Wrap privileged commands in `timeout` so an unanswered dialog can't block.
  Note `dmesg_restrict=1`: reading the kernel log needs `pkexec dmesg`.

## Never
- Destructive commands (`rm -rf`, `reset --hard`, force push) without explicit
  approval.
- Print secrets or credentials.
- Fabricate test results.
