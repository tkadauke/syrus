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
