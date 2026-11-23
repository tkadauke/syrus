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

The architecture allowlists are deliberately explicit. Additions require a
comment explaining why an existing migration still needs the entry; never add
a wildcard or directory-wide exemption.

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
- **Manifest declarations:** `workflow_kinds`, `job_origin`, `slug_type`,
  `problem_provider`, `repository_configuration`, `step_environment`, and
  `worker_capability_probe` become data rather than provider classes.
- **Standalone pending a verified family contract:** `preview_provider`,
  `memory_store`, `platform_delivery`, `repository_recommendation`,
  `workflow_artifact_contributor`, `grader_failure_summarizer`,
  `grader_input_materializer`, `test_evidence`, and `approval_provider`.
  These remain standalone because their lifecycle or
  ownership was unresolved in the audited design; do not absorb them by name
  alone.

Non-registry APIs also have targets: `Filters.register_subject` and
`Filters.register_chips` go to Surface; `CredentialProbe.register_probe` and
`register_secret_extractor` go to Toolkit; `Installer.define` goes to Lifecycle
hooks; Job, Workflow, Step, and WorkDefinition kind registries go to manifest
declarations. They stay on their current APIs until those families explicitly
adopt them.
