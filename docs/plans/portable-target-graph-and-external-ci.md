# Portable Target Graph and External CI Contracts

## Status

Design proposal. This document separates an urgent external-check mapping fix
from a longer-term target compiler and runner. The latter is a north star, not
an onboarding requirement.

## Problem

Syrus currently has two validation systems that can disagree:

1. Syrus graders are executable, structured checks known to the workflow
   engine. They can run focused tests, ingest JUnit, retry failures against the
   base revision, and provide repair agents with reproducible evidence.
2. GitHub check runs are external status signals. A check may cover more or
   less work than a Syrus grader, may use a different environment, and may not
   have any Syrus command capable of reproducing it.

Treating every failed GitHub check as a landing blocker creates an invalid
state: a check blocks landing while no grader can reproduce or repair it.
Inferring correspondence from names does not solve this safely. Generic names
such as `test`, `build`, `lint`, and `rspec` routinely refer to different work
in different systems.

At the same time, requiring every repository to adopt a build DSL would make
Syrus unnecessarily difficult to use. A repository with conventional Ruby,
JavaScript, or Go structure should continue to receive useful defaults from
plugins with little or no configuration.

The design therefore needs:

- explicit external-check mappings now;
- many-to-many relationships between checks and targets;
- a canonical target representation shared by all execution paths;
- progressive disclosure from inference to portable target definitions;
- a standalone planner and runner with transparent commands and output;
- native integration with existing build systems such as Buck, without
  rebuilding their dependency graphs inside Syrus;
- runtime attestations that prevent mappings from silently drifting.

## Design Principles

### Every blocker has an execution contract

A check may block Syrus landing only when it is explicitly mapped to a
reproducible target, or explicitly declared as an external-only gate. An
unmapped check remains visible but is informational.

GitHub branch protection is an unavoidable external constraint. If GitHub
itself requires an unmapped check, Syrus reports an unmapped external GitHub
gate. It must not pretend the check is a repairable grader failure.

### Mapping is explicit

Exact-name matching may produce a configuration suggestion, but never an
enforced mapping. Plugin detection may propose configuration, but the operator
must be able to see what became authoritative.

### Routing and proof are different

An external check mapping answers which targets can investigate a failure.
It does not automatically mean that a passing external check proves those
targets healthy enough to skip local execution. Result reuse requires a
separate, stronger proof contract.

### One canonical graph

Inferred plugin graders, configured typed graders, portable rule targets, and
delegated Buck targets all lower into the same internal target representation.
Selection, dependency traversal, scheduling, result recording, and UI
presentation operate on that representation rather than special-casing each
source.

### Transparency is non-negotiable

Every target execution must expose:

- the exact command and working directory;
- why the target was selected;
- its direct and transitive dependencies;
- relevant inputs and declared outputs;
- environment variable names forwarded to the process;
- target, graph, command, and dependency fingerprints;
- whether prior health was reused and why;
- raw process output and structured result artifacts.

## Progressive Adoption

### Level 1: inferred targets

A repository without Syrus configuration receives targets inferred by
installed plugins. For example, the Ruby plugin may detect RSpec and produce a
synthetic test target with full, focused, failed-case, CI, coverage, and
base-revision-retry behavior.

This graph is available inside Syrus only. It provides a zero-configuration
workflow, but external CI cannot independently attest that it ran the same
target definition. Unmapped GitHub checks are informational at this level.

### Level 2: minimal typed configuration

A repository may opt into a plugin-defined grader and map external checks
without adopting a target language:

```yaml
grade:
  - type: rspec
    ci_checks:
      - rspec
```

The Ruby plugin lowers `type: rspec` into a canonical target. A failing mapped
GitHub check routes repair to that target. This is a mapped reproduction, not
proof that GitHub and Syrus ran byte-identical commands.

Most repositories should be able to stop at this level.

### Level 3: portable target definitions

Repositories that need identical local, Syrus, and CI execution may adopt a
portable target language. The repository then contains enough information to
compile its graph in any environment without consulting the Rails plugin
registry.

This language may eventually be Starlark-like, with deterministic evaluation,
portable rule libraries, macros, matrices, and a small set of generic lowered
target primitives. `.syrus.yml` can remain the home for workflow and delivery
policy while root and nested target files define execution.

Portable targets are an advanced capability, not a prerequisite for basic
Syrus use.

### Level 4: native build-system delegation

Repositories already using Buck should keep Buck authoritative for dependency
analysis and execution. Syrus imports or references Buck labels and delegates
queries and tests to Buck rather than compiling BUCK files into a competing
graph.

## External Check Mapping

### Many-to-many model

External checks and Syrus targets form a bipartite graph:

- external check nodes;
- canonical target nodes;
- `routes_to` edges for failure reproduction;
- optional `proves` edges for health reuse;
- explicit satisfaction policies for grouped evidence.

One broad GitHub check may route to many targets:

```yaml
external_checks:
  - name: rspec
    repair_targets:
      - //:grade/rspec-ci
      - //plugins/*:grade/rspec-ci
```

When that check fails, Syrus should:

1. Use structured check artifacts to identify the owning target when possible.
2. Otherwise intersect the mapped targets with the affected target graph.
3. If attribution remains ambiguous, run all affected mapped targets in
   parallel.
4. Let each test target perform its own base revision retry.
5. Treat an external failure that no mapped target reproduces as an external
   environment or unreproduced failure, not as an endlessly repairable code
   defect.

Many GitHub checks may route to one target when they independently exercise the
same behavior. If the checks partition behavior, the preferred model is to
split the local target into corresponding child targets. A temporary grouped
evidence policy may express `all_of` or explicitly authorized `any_of`
semantics, but `all_of` is the safe default.

### Immediate landing behavior

- A mapped failing check participates in attribution, CI repair, and landing.
- An unmapped check is displayed but does not block Syrus landing.
- A GitHub-required unmapped check is displayed as an external blocker because
  the merge API will reject the merge regardless of Syrus policy.
- Name similarity creates a suggested mapping only.
- Duplicate or ambiguous proof mappings are configuration errors unless an
  explicit group policy resolves them.

### Base attribution

External-check attribution must compare the same named check on the exact base
SHA. Missing base evidence means unknown, not PR-specific. A result from a
different base revision must not prove inheritance or ownership.

## Canonical Target Representation

Every target source lowers into a versioned representation similar to:

```json
{
  "label": "//plugins/search:grade/rspec",
  "kind": "test",
  "command": {
    "full": ["bundle", "exec", "rspec"],
    "focused_files": ["bundle", "exec", "rspec", "{files}"],
    "failed_cases": ["bundle", "exec", "rspec", "{locations}"]
  },
  "working_directory": "plugins/search",
  "inputs": ["**/*.rb"],
  "test_files": ["spec/**/*_spec.rb"],
  "dependencies": ["//plugins/search:prepare"],
  "outputs": {
    "junit": ".syrus/results/search-rspec.xml"
  },
  "phases": ["review", "landing", "ci"],
  "capabilities": {
    "focused_files": true,
    "failed_cases": true,
    "base_revision_retry": true
  },
  "provenance": {
    "kind": "plugin_configured",
    "provider": "ruby",
    "rule": "rspec",
    "version": "1"
  }
}
```

Supported provenance includes:

- `plugin_inferred`;
- `plugin_configured`;
- `portable_rule`;
- `buck` or another delegated build system.

The executor consumes the lowered target. It should not need framework-specific
Ruby plugin logic after lowering.

## Plugin-Defined Grader Types

Plugin-defined types remain the low-complexity authoring interface. The Ruby
plugin's RSpec type continues to define sensible defaults for:

- source and test scopes;
- full, focused, and CI commands;
- tags and CI-only filtering;
- JUnit and coverage outputs;
- failed-case selection;
- base revision retry;
- touched-test flakiness checks;
- prepare dependencies.

Initially, Ruby plugin code performs this expansion inside Syrus. Over time,
standard types may gain portable companion rule packages. Both implementations
must lower into the same canonical representation and can be compared in
shadow mode before portable compilation becomes authoritative.

Plugins may discover and recommend targets. Portable repository definitions
must completely define how their targets compile and run without requiring the
application plugin registry.

## Standalone Target Tool

The target tool should support inspection, planning, and execution:

```text
syrus targets list
syrus targets show //plugins/search:grade/rspec
syrus targets graph //plugins/search:grade/rspec
syrus targets affected --base origin/main --kind test
syrus targets explain //plugins/search:grade/rspec --base origin/main
syrus targets why //plugins/search:grade/rspec
syrus targets plan --phase landing --base origin/main
syrus targets run //plugins/search:grade/rspec
syrus targets run --plan plan.json --report result.json
```

Planning and execution are separate. A plan records the source SHA, graph
fingerprint, selected targets, exact commands, dependency closure, and
selection reasons. Syrus may dispatch each executable target to a different
worker. GitHub may execute the same plan locally or convert it into a job
matrix.

The tool must use one canonical graph implementation. Reimplementing parsing
and traversal independently in Rails and Go would recreate the drift problem.
A future Starlark evaluator and graph engine may live in the standalone tool;
Rails then becomes a scheduler and presenter that consumes versioned plan and
result protocols.

## Runtime Events and Results

Execution emits human-readable logs and structured JSONL events:

```json
{"event":"target_started","label":"//:grade/rspec","command":["bundle","exec","rspec"]}
{"event":"process_output","stream":"stdout","data":"..."}
{"event":"artifact","kind":"junit","path":".syrus/results/rspec.xml"}
{"event":"target_finished","outcome":"failed","exit_code":1}
```

The final result report includes:

- source SHA;
- target and graph fingerprints;
- compiler and runner versions;
- exact command and working directory;
- duration and resource use;
- exit status;
- structured test failures;
- artifacts;
- base revision retry outcome;
- touched-test flakiness outcome;
- dependency outcomes.

The UI continues showing commands and raw output. Structured events add
selection, attribution, and reuse information rather than replacing terminal
visibility.

## CI Attestations and Drift Prevention

Hand-maintained name mappings are not sufficient for long-term equivalence.
Portable CI should emit a machine-readable target report:

```json
{
  "schema_version": 1,
  "source_sha": "...",
  "graph_fingerprint": "...",
  "targets": [
    {
      "label": "//:grade/rspec-ci",
      "fingerprint": "...",
      "outcome": "passed"
    }
  ]
}
```

The visible GitHub check name is presentation. The attested target labels are
identity.

Syrus validates:

- the report SHA equals the PR head;
- all reported labels exist;
- target and graph fingerprints match current compilation;
- all expected CI targets were reported;
- configured mappings are still observed;
- newly observed checks are mapped or intentionally informational;
- path filters did not silently omit required targets.

Repository diagnostics should surface stale mappings, missing targets,
unmapped checks, likely renames, fingerprint mismatches, and incomplete CI
reports. Exact-name similarity may drive a suggested fix but never silently
change enforcement.

## Buck Integration

Buck remains authoritative for repositories that use it. A Buck provider
maps Syrus workflow phases and target-selection requests to Buck labels and
queries, for example:

```text
buck2 uquery <affected-expression>
buck2 test //path/to:target
```

The canonical Syrus graph contains delegated nodes that reference Buck labels.
It does not duplicate Buck's full dependency graph. Planning records the query,
selected labels, and reason for selection; execution records the exact Buck
command, event log, test artifacts, and results.

A minimal repository configuration might look like:

```yaml
build_system:
  type: buck2

grade:
  - type: buck2_test
    targets:
      - //...
    ci_checks:
      - buck2-tests
```

The same adapter boundary should support other established build systems when
their native graph is more authoritative than Syrus file-glob inference.

## Target Selection

Selection should be conservative and explainable:

1. Compute changed files relative to the appropriate base.
2. Determine directly affected source or delegated build-system targets.
3. Traverse reverse dependencies to validation targets.
4. Restrict executable validation targets to the workflow phase.
5. Include their transitive execution dependencies.
6. Apply valid target-health reuse only after selection.
7. Record a reason for every selected, reused, or skipped target.

File globs are one source of graph edges. They should not remain an independent
grader-only filtering mechanism once equivalent graph information exists.

## Rollout

### Phase 1: explicit external-check routing

- Add explicit many-to-many mappings to current grader targets.
- Ignore unmapped checks for Syrus landing.
- Distinguish mapped, informational, and external-only required checks.
- Require exact-base evidence for inherited-check attribution.
- Add diagnostics for unmapped checks and stale mappings.

### Phase 2: canonical targets

- Define versioned target, plan, event, and result schemas.
- Lower current inferred and configured plugin graders into canonical targets.
- Preserve current command, log, artifact, BRR, and flakiness behavior.
- Compare old and canonical selection in shadow mode.

### Phase 3: standalone planning and execution

- Add list, show, graph, affected, explain, plan, and run commands.
- Make Syrus worker Steps invoke one planned target each.
- Retain distributed fanout and resource admission.
- Move prepare, format, generate, and build execution onto the same runner
  where appropriate.

### Phase 4: external CI attestations

- Run canonical targets in GitHub CI.
- Publish structured target reports and fingerprints.
- Prefer attested target identity over check-name mappings.
- Add drift and completeness diagnostics.

### Phase 5: portable rules and native graph providers

- Introduce the optional portable target language and standard rule packages.
- Add Buck query and execution delegation.
- Migrate standard RSpec, Vitest, Go, and Playwright definitions where shared
  execution provides value.
- Keep inference and minimal typed configuration as supported entry points.

## Non-Goals for the Initial Work

- Reimplementing Buck's artifact cache or hermetic sandbox.
- Requiring target files for newly onboarded repositories.
- Treating matching names as proof of equivalence.
- Replacing plugin detection and onboarding assistance.
- Marking external results reusable merely because they route to a target.
- Running an entire target graph on one worker and losing distributed fanout.

## Core Invariants

1. No anonymous external check silently becomes an unrepairable landing gate.
2. Every enforced mapping is explicit and inspectable.
3. Missing base evidence is unknown, never PR-specific by default.
4. Routing a failure does not automatically prove target health.
5. Every target execution exposes its exact command and selection reason.
6. The same canonical target representation drives local, distributed, and CI
   execution where portable definitions are available.
7. Repositories may remain on inferred or minimally configured targets without
   adopting the portable DSL.
8. Existing build systems remain authoritative for their native graphs.
