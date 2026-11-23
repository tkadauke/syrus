# Capability-family migration

Migrate one family without a flag day by keeping legacy registry reads as the
temporary compatibility boundary. Do not make core callers merge legacy and
family registrations themselves.

## Playbook

1. Measure before editing. For every legacy point, run
   `rg -n 'providers_for\([ :]*<point>|provides:?.*<point>|<point>:' app lib plugins spec`
   and record core lookup sites separately from plugin registrations. Read each
   lookup to identify its real composition rule, decline value, and error
   handling; a raw match count is not a contract.
2. Define the family, capability contracts, contexts, composition modes, and
   absent behavior. Mark a family as indicating language support with the
   capability that detects it (for example,
   `indicates_language_support capability: :detect_prepare`) when its
   declaration should participate in `RepoPluginDetector`. This declaration is
   independent of legacy mappings and remains after their adapters are removed.
   The named capability must use `Syrus::Plugin::Context::RepoContext`.
3. Declare every absorbed legacy point with `legacy`, its replacement
   capability, and an adapter that exposes the old method names. The adapter
   translates arguments into the typed context; it must not guess capabilities
   from `respond_to?`.
4. Add the bridge before moving a plugin. `PluginRegistry.providers_for` then
   returns legacy registrations and adapted family providers in plugin priority
   order. Treat the duplicate-registration report as migration work: a plugin
   may use both forms briefly, but it must not remain doubled.
5. Move core call sites to `Syrus::Plugin::Dispatch.call`. Do this before a
   family is marked migrated. Once marked, the architecture check permits no
   direct core lookup of its absorbed legacy points.
6. Move plugins one at a time. Replace their legacy manifest entries with one
   or more family declarations, add generated family contract examples, and
   keep behavior-specific plugin specs.
7. When the last plugin and caller have moved, delete the legacy extension
   points, adapters, bridge allowlist entries, and duplicate-report handling.

## What the Ecosystem migration taught us

- Move shared behavior that happened to live in a legacy interface module into
  a family-owned helper before deleting the interface. Coverage-phase selection
  was behavior used by providers, not part of registration validation.
- Detection must declare its role in the family definition. A generic detector
  cannot infer language support from capability names or from a legacy mapping
  after the bridge disappears.
- Removal needs a boot-isolation regression, not only registry assertions.
  External plugins can lag behind core, so an obsolete declaration must become
  a clear plugin-health finding while the host continues booting.
- Generated catalogs prove structural freshness, but the handwritten authoring
  guide still needs an explicit before/after migration example and reasons for
  every capability that remains provisional.

## What the Review and Policy migration taught us

- Dispatch's `decline` is what a provider returns when it has nothing to add;
  the capability's `failure` is what the dispatcher substitutes when a provider
  raises, times out, trips its circuit breaker, or returns an invalid value. It
  defaults to `decline`. Authorization-adjacent families set it apart: Policy
  uses `failure: -> { [Policy::FAIL_CLOSED] }` so callers (`JobVisibility`,
  `Policy.filter_repositories`) show non-admins nothing instead of widening
  visibility. Every restriction applies; none may drop out silently.
- Moving the provider list for review gates must not change gate semantics:
  core still wraps each gate operation in `PluginInvocation`, so a failing
  `review_gates` operation declines exactly as before, and the immutable-HEAD
  barrier and definition validation are untouched.
- Modules-returning capabilities share `Syrus::Plugin::ContributionProvider`
  (lazy provider constants plus the legacy adapter); reuse it for facets whose
  interfaces are still multi-operation.

## What the service-family migration taught us

- Services (AgentRuntime, ExecutionBackend, RuntimeSession, SourceHost,
  SpeechToText) keep their large stateful interface modules as the contract.
  The family declares shape `service` (required core `key`, `display_name`,
  `available_for?`) and reuses only declaration, dispatch, bridge and
  conformance machinery. Each capability returns the plugin's service class;
  never force a service into the facet capability mold.
- Capability names equal the legacy point names here, so a `point:` text scan
  cannot tell a legacy registration from a family declaration. Architecture
  checks read manifest `provides` keys instead.
- Selection stays with the service and its facade: provider-key lookup
  (`AgentProviders.for`), per-repository `available_for?`, replica-before-
  upstream ordering in `RepositoryContent`, and the `Execution::Router` claim
  loop (including its fail-closed handling) are unchanged. Core only swaps the
  list source for `Syrus::Plugin::ServiceProvider.providers(capability)`.
- Lookup cost was measured before moving callers: 300 `agent_provider` lookups
  averaged about 2.4 ms through `providers_for` and 2.3 ms through the
  dispatcher, so the move adds no measurable cost.
- Code that reads a manifest directly (disable guards, onboarding) must use
  `ServiceProvider.for_manifest`, because family declarations are not in
  `manifest.provides`.
- A capability is stable only with two in-tree implementations: `agent_provider`,
  `chat_provider`, `runtime_session_provider`, `input_source`, and
  `repository_content_provider`. `execution_backend`, `source_control_provider`,
  `workspace_git_transport`, and `speech_to_text_provider` are provisional
  because one bundled plugin implements each.

## What the hook-family migration taught us

- Hooks are broadcast or all-must-participate, so write the real composition
  and failure rule before defining the family, then preserve it:
  - Lifecycle callbacks are broadcast and manifest-scoped. `on_disable` must
    reach a plugin that was just disabled, so jobs and `PluginRecord` read one
    manifest's callbacks through `Lifecycle.callback_providers_for` (the
    registry's `manifest_providers_for`, which applies the bridge) rather than
    the enablement-filtered dispatcher. A failing `on_boot` drains only that
    plugin's effects; `on_shutdown` always drains; enable and disable drain on
    failure and re-raise.
  - Domain subscribers already isolated failures: each runs in its own
    `PluginInvocation`, async delivery is one job per subscriber on the plugin's
    home queue. The migration kept the `:domain_subscriber` invocation label.
  - Retention and purge are collect: every contributor participates. The
    capability `failure` is a `DataPolicy::UNAVAILABLE` marker, so a contributor
    that cannot be resolved is reported (retention logs an error, a purge report
    lists it, a purge result records it) while the others still run. Previously
    a contributor whose `purge!` raised was dropped without any line in the
    result; it is now reported.
  - Preview-panel retention is an any-of decision; a declining provider does
    not retain the panel.
- Cores that look up an owning plugin by `manifest.provides[...]` miss family
  declarations. Use `PluginRegistry.plugin_name_for` (and make provider
  `owns_implementation?` accept modules, not only classes), and pin it with an
  architecture check on `provides[:point]` reads as well as `providers_for`.
- `Installer.define` stays the engine. Plugin-facing registration of
  `while_enabled`/`always` effects goes through `Lifecycle.define_effect`;
  core registries that install their own contributions (for example kind
  registries) keep calling the Installer until their own families adopt it.
- Every capability is provisional. `callback_providers`, `domain_subscribers`,
  `retention_policies`, and `purge_contributors` still return multi-operation
  behavior modules whose interfaces have not been decomposed, and
  `preview_panel_retentions` has a single bundled implementation.

## What the manifest-declaration migration taught us

`workflow_kinds`, `job_origin`, `slug_type`, `problem_provider`,
`repository_configuration`, `step_environment` and `worker_capability_probe`
are not capability families. Their useful content is static, so they became
manifest *data* (`Syrus::Plugin::Declarations`) rather than providers dispatched
through `Syrus::Plugin::Dispatch`. A declaration is a plain hash validated while
the manifest is parsed; behavior that cannot be data is named by a constant
string and resolved only when it is used.

- **Introspectable without plugin code.** A manifest lists every kind, origin
  key, slug prefix and link template, problem code, config key, forwarded ENV
  name and probe token without constantizing anything. A spec registers
  declarations naming nonexistent classes and reads all of them. Only the
  `resolver`, `provider`, `extra_env`, `probe` and `work_definitions` names are
  loaded, at the call that needs them, and fail there.
- **Two validation layers.** The DSL call raises `InvalidDeclaration` naming the
  plugin and field. The loader isolates it, so an external plugin built for a
  different core is a failed plugin-health finding and the host keeps booting
  (one boot-isolation regression per declaration plus an unknown point).
  `PluginRegistry.register` re-checks declarations that bypass the DSL and
  records `validation_errors` instead of raising, and runs the one check that
  needs core constants: a worker probe's `dimension`.
- **The bridge adapts, core does not merge.** `providers_for(point)` returns a
  plugin's registered provider classes and adapted declarations in plugin
  priority order, so no core call site changed shape. Core callers that read a
  manifest directly (`WorkDefinitions`, the disable guard, repository
  configuration) use `manifest_providers_for`, because a declaration is not in
  `manifest.provides`. A plugin that declares a point and still registers a
  class for it shows in `declaration_duplicate_registrations`.
- **Core kinds stay in core.** `Job::Kind`, `Workflow::TriggerKind` and
  `Step::Kind` keep their built-in tables; `KindRegistry` still refuses a
  declaration that shadows a built-in. Declarations carry strings (`agent_role`,
  `placement_policy`, `feedback_kind`); the adapter restores the few symbol
  fields. Allowed keys are pinned to the entry classes' members by a spec
  (`diff_review_labeler` and `dynamic_required_mcp_tools` hold callables and are
  deliberately not declarable; a plugin that needs them keeps a provider class
  until core has a data form).
- **When each is read** (measured at the call sites, not by match count):

  | Point | Read | Notes |
  | --- | --- | --- |
  | `workflow_kinds` | `Installer.sync!` on every kind-table read; `WorkDefinitions.registry` on first use and per registry generation | Hot, but reads cached adapters. Constants load only for `work_definitions`. |
  | `job_origin` | Per Job render, approval, prompt | Origin key is matched from data; the behavior class loads only for the matching origin. |
  | `slug_type` | Per slug resolution and in the bootstrap payload | Bootstrap metadata is pure data and loads no plugin code. |
  | `problem_provider` | `Problem::Kind` registry install | Namespace and code ownership are checked at parse time. |
  | `repository_configuration` | Each `.syrus.yml` parse | Key, version and legacy keys are data; the parser class loads only for a present key. |
  | `step_environment` | Each prepare, grader step, and chat workspace prepare | Forwarded names are data; `extra_env` loads only when declared. |
  | `worker_capability_probe` | Worker capability detection, after Rails loads | Queue config renders before Rails and sees no plugin probes, as before. The probe may only report its declared dimension and token. |

- Every bundled plugin was migrated; none registers a provider class for these
  seven points. No bundled plugin registers `problem_provider` (core's registry
  accepts it, and a spec covers the declaration path), so the delete-the-bridge
  step for that point waits for the first user.

## What the Review and Policy removal taught us

Review (seven points) and Policy (two points) were the first facets whose legacy
points were deleted after the Ecosystem family. What the removal taught us:

- Removal is small when core has already moved: no core call site read these
  points, so the work was the registry tables (`EXTENSION_POINTS`,
  descriptions, `INTERFACE_FOR`), the family definitions, and fixtures.
- Replace the `CAPABILITY_FOR_LEGACY` hash (legacy point to capability) with a
  plain `CAPABILITIES` list. The point names do not belong in the family once the
  adapter is gone.
- Specs that registered fixtures with `provides: { point: Module }` or
  `register(:point, instance)` are the bulk of the cost. A shared helper
  (`register_contributions`, `spec/support/contribution_providers.rb`) builds the
  family declaration so each call site changes by one word.
- Two legacy behaviors vanish with the bridge and were deliberately not
  re-created: the registration-time check that a module includes its interface
  module, and `providers_for` answering for the point. Family providers are
  validated by the family's return shape instead.
- Every removed point gets a boot-isolation regression in `plugin_loader_spec`:
  an external plugin that still declares one is a failed plugin-health finding
  (`Unknown extension point :point`) and the host keeps booting.

### Still to remove

The bridge, adapters, and legacy points remain for the families that were not
removed in this pass, and their removal follows exactly the steps above:
Lifecycle and DataPolicy (the plugin generator, test kit, `register_plugin_provider`
matcher, loader fixtures, and the `Lifecycle.callback_providers_for` manifest-scoped
read must move together; a family-based manifest read is needed because
`manifest_providers_for` applies the bridge), ChatIntegration, Surface, Toolkit,
and the five service families (specs register services directly through
`register(:point, instance)`, which needs a family-level direct registration
first). The manifest-declaration points still answer through
`Declarations.providers_for_manifest`; their core callers
(`WorkDefinitions`, `SlugRefs::Resolver`, `Job::Origin`, `Steps::Prepare`,
`SystemAlerts`) have not moved to a declaration reader yet. Until the last
family is removed, `LegacyBridge`, its duplicate report, and the architecture
allowlists stay.

The architecture allowlists are deliberately explicit. Additions require a
comment explaining why an existing migration still needs the entry; never add
a wildcard or directory-wide exemption.

## Permanently standalone points

The design audit left nine points standalone because their lifecycle or
ownership was unresolved. Each was re-read against its interface module, every
core lookup, and every bundled registration. None is absorbed, because none
fits a family capability as it is shaped today, and absorbing by name would only
rename the registry. They stay registered in `EXTENSION_POINTS` with their legacy
interface, and `spec/architecture/plugin_family_migration_spec.rb` pins that
each has a decision here and no family mapping. Revisit a point only when the
stated condition changes.

- **`preview_provider`**: two bundled implementations (`rails`, `javascript`), but
  the contract is a multi-call stateful object: `detect?(repo_path)` claims a
  repository and the same instance is then asked for `start_command`,
  `seed_command`, `env_for`, `setup_commands`, `health_check_path`, and
  `log_paths`. Family dispatch returns one value per capability invocation and
  cannot hand back a claimed session. The interface also owns a process-local
  `registry` that core and specs append to, so selection merges two sources that
  no plugin declaration covers. Revisit if dispatch gains a claim-then-session
  composition.
- **`memory_store`**: `Syrus::Plugin::MemoryStore` is an empty marker; the real
  contract is the three duck-typed calls `Syrus::Memory` makes
  (`prompt_context`, `chat_context_lines`, `chat_instructions`). Selection is an
  exclusive slot (`providers_for(...).first`), not a composition, and the facade
  already owns the degrade-quietly rule. One bundled implementation
  (`agent_memory`). A family adds nothing the facade does not already own.
- **`platform_delivery`**: one bundled implementation (`discord`). The contract
  is class-level (`platform_key`, `connector_job_class`, `platform_config_class`)
  plus an instance `deliver`, and core uses it to start connector jobs at boot,
  to look up an adapter by platform key, and to extend the `PlatformIdentity`
  platform list. That is connector lifecycle owned by `PlatformDelivery::Registry`
  and keyed selection, not a capability a dispatcher can compose, and it belongs
  with the chat and platform pluginization work. Revisit there.
- **`repository_recommendation`**: one `collect` operation returning core's
  recommendation hash, with core adding the dismissal key and swallowing errors.
  One bundled implementation (`scheduled_tasks`). There is no selection,
  lifecycle, or failure rule beyond what core already applies, so a family would
  add declaration and catalog machinery for a single provisional capability.
- **`workflow_artifact_contributor`**: one operation (`for_job`) merged into a
  hash by key, one bundled implementation (`container_execution`). The merge is
  last-writer-wins on artifact keys, which is a hash rule dispatch composition
  does not express. Revisit when a second contributor needs a collision rule.
- **`grader_failure_summarizer`**: one `collect` operation
  (`summarize_grader_failure`) whose lines core never inspects, with a raising
  summarizer dropped with a warning. Its only implementation is `test_insights`,
  and it is a seam inside `Steps::GraderCollect` between the grader pipeline and
  Test Insights. Test Insights is a core feature that ships as a plugin, so this
  is the grader pipeline's own contract rather than a third-party extension
  surface. Revisit if a second grader-evidence source appears.
- **`grader_input_materializer`**: one broadcast operation
  (`materialize_grader_inputs`) run during distributed grader source
  materialization, again with `test_insights` as the only implementation. It
  runs against an immutable snapshot checkout and warns instead of failing the
  grader, rules that belong with the distributed-grader contract rather than a
  facet. Revisit with a second implementation.
- **`test_evidence`**: a three-operation duck-typed interface
  (`failed_test_cases`, `failed_test_summary`, `test_case_count`,
  `failed_test_identities`) where core probes `respond_to?` per operation and
  deduplicates results by test identity. A family would have to decompose it
  into separate capabilities first, and `test_insights` is the only
  implementation. Revisit if a second test-result source appears.
- **`approval_provider`**: no bundled implementation exists, so there is no
  second implementation to derive a contract from and nothing to conform-test.
  Selection is by the persisted delegation's `provider_key` against
  `provider_key`, with human-only and ceiling checks in core before a provider is
  asked to `decide`. Because it is authorization-adjacent, any family must set an
  explicit fail-closed `failure`; designing that without a real provider would be
  guesswork. Revisit when the first approval provider plugin is written.

## Extension-point target inventory

All current registry points have a target. A dagger in the design audit meant
the original classification came from names and registrants; verify the actual
interface again when beginning that family.

- **Ecosystem facet:** `prepare_detector`, `grade_detector`, `grader_type`,
  `grader_augmentor`, `review_criteria_provider`, `autofix_command`,
  `dependency_audit_command`, `focused_test_command`, `coverage_analyzer`,
  `affected_test_analyzer`, `ci_log_parser`, `prompt_injector`,
  `diff_review_file_pattern_provider`, `build_system_graph_provider`.
- **Toolkit facet:** `mcp_tool_set`, `chat_mcp_tool_set`,
  `permission_provider`, `mcp_run_context_contributor`.
- **Surface facet:** `sidebar_page`, `admin_page`, `repo_page_tab`,
  `workspace_tab`, `ui_slot`, `artifact_renderer`, `preview_panel_viewer`.
- **ChatIntegration facet:** `chat_payload_contributor`,
  `chat_prompt_injector`, `chat_media_source`, `chat_turn_orientation`,
  `chat_turn_finalizer`, `chat_workspace_lifecycle`, `chat_turn_lifecycle`,
  `chat_job_status_extension`, `chat_identity_provider`, `mentionable`.
- **Review facet:** `review_gate`, `reviewer_target_provider`,
  `review_context_contributor`, `review_presentation_contributor`,
  `post_implementation_review_provider`, `diff_review_annotation_provider`,
  `adjudicator`.
- **Policy facet:** `job_visibility_restriction`, `repository_filter`.
- **Services:** AgentRuntime owns `agent_provider` and `chat_provider`;
  ExecutionBackend owns `execution_backend`; RuntimeSession owns
  `runtime_session_provider`; SourceHost owns `source_control_provider`,
  `input_source`, `repository_content_provider`, and `workspace_git_transport`;
  SpeechToText owns `speech_to_text_provider`.
- **Hooks:** Lifecycle owns `callbacks` and `domain_subscriber`; DataPolicy owns
  `retention_policy`, `purge_contributor`, and `preview_panel_retention`.
- **Manifest declarations (migrated):** `workflow_kinds`, `job_origin`,
  `slug_type`, `problem_provider`, `repository_configuration`,
  `step_environment`, and `worker_capability_probe` are data rather than
  provider classes; see the manifest-declaration section above.
- **Permanently standalone:** `preview_provider`, `memory_store`,
  `platform_delivery`, `repository_recommendation`,
  `workflow_artifact_contributor`, `grader_failure_summarizer`,
  `grader_input_materializer`, `test_evidence`, and `approval_provider`. Each was
  checked against its real interface and callers; the reasons are recorded in
  [Permanently standalone points](#permanently-standalone-points).

Non-registry APIs also have targets: `Filters.register_subject` and
`Filters.register_chips` go to Surface; `CredentialProbe.register_probe` and
`register_secret_extractor` go to Toolkit; `Installer.define` goes to Lifecycle
hooks; Job, Workflow, Step, and WorkDefinition kind registries go to manifest
declarations. They stay on their current APIs until those families explicitly
adopt them.
