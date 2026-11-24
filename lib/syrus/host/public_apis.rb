require "syrus/host"
require "syrus/host/backup_artifact_source"
require "syrus/host/backup_destination"
require "syrus/host/chat_titles"
require "syrus/host/disk_usage"
require "syrus/host/agent_runtime"
require "syrus/host/system_alert"
require "syrus/host/system_alert_provider"
require "syrus/host/external_reviewer"
%w[
  agent_provider callbacks permission_provider repository_content_provider
  cli_command_handler
].each { |name| require "syrus/plugin/#{name}" }
require "syrus/host/admin_page"
require "syrus/plugin_invocation"

module Syrus
  module Host
    module PublicApis
      ALIASES = {
        PluginApi: "Syrus::PluginApi",
        AgentProvider: "Syrus::Plugin::AgentProvider",
        AdminPage: "Syrus::Plugin::AdminPage",
        Callbacks: "Syrus::Plugin::Callbacks",
        PermissionProvider: "Syrus::Plugin::PermissionProvider",
        RepositoryContentProvider: "Syrus::Plugin::RepositoryContentProvider",
        CliCommandHandler: "Syrus::Plugin::CliCommandHandler",
        BackupArtifactSource: "Syrus::Plugin::BackupArtifactSource",
        BackupDestination: "Syrus::Plugin::BackupDestination",
        SystemAlertProvider: "Syrus::Plugin::SystemAlertProvider",
        ExternalReviewer: "Syrus::Plugin::ExternalReviewer",
        ExternalReviewContext: "Syrus::Plugin::ExternalReviewContext",
        ExternalReviewResult: "Syrus::Plugin::ExternalReviewResult",
        ExternalReviewArtifact: "Syrus::Plugin::ExternalReviewArtifact",
        InvocationResult: "AgentInvocation::Result",
        ToolContext: "McpToolContext",
        Current: "Current",
        Record: "ApplicationRecord",
        BackgroundJob: "ApplicationJob",
        McpTools: "Mcp::Tools",
        AdminController: "Api::V1::Admin::BaseController",
        AppController: "Api::V1::App::BaseController",
        AppAdminController: "Api::V1::App::Admin::BaseController",
        ProcessRunner: "ProcessRunner",
        OperationalLogging: "OperationalLogging",
        PerformanceLogging: "PerformanceLogging",
        Metrics: "Syrus::Metrics",
        PluginRegistry: "Syrus::PluginRegistry",
        PluginInvocation: "Syrus::PluginInvocation",
        CapabilityValidationError: "Syrus::Plugin::Dispatch::ValidationError",
        EcosystemGraderCoverage: "Syrus::Plugin::Ecosystem::GraderCoverage",
        EcosystemPreparePlan: "Syrus::Plugin::Ecosystem::PreparePlan",
        EcosystemDependencyAuditPlan: "Syrus::Plugin::Ecosystem::DependencyAuditPlan",
        Toolkit: "Syrus::Plugin::Toolkit",
        GraderStep: "SyrusYml::GradeStep",
        GraderBaseRetry: "SyrusYml::BaseRetry",
        GraderDefaults: "Syrus::Plugin::Ecosystem::GraderDefaults",
        GraderResourceRequest: "GraderResourceRequest",
        GraderExecutionCapabilities: "TargetGraph::ExecutionCapabilities",
        TestRunResult: "JunitXmlParser::ParsedRun",
        TestCaseResult: "JunitXmlParser::ParsedCase",
        CoverageParseResult: "CoverageAnalysis::Parsers::Base::ParseResult",
        WorkflowWorkspace: "WorkflowWorkspace",
        GitRunner: "GitRunner",
        CapabilityDescriptor: "Permissions::CapabilityDescriptorAdapter",
        ExecutionBackend: "Syrus::Plugin::ExecutionBackend",
        InputSource: "Syrus::Plugin::InputSource",
        SourceControlProvider: "Syrus::Plugin::SourceControlProvider",
        SpeechToTextProvider: "Syrus::Plugin::SpeechToTextProvider",
        PlatformDelivery: "Syrus::Plugin::PlatformDelivery",
        PurgeContributor: "Syrus::Plugin::PurgeContributor",
        WorkerCapabilityProbe: "Syrus::Plugin::WorkerCapabilityProbe",
        WorkflowArtifactContributor: "Syrus::Plugin::WorkflowArtifactContributor",
        WorkspaceGitTransport: "Syrus::Plugin::WorkspaceGitTransport",
        AgenticConnection: "Syrus::Plugin::AgenticConnection",
        GatedToolSet: "Syrus::Plugin::GatedToolSet",
        ContentSource: "RepositoryContent::Source",
        ContentRevision: "RepositoryContent::Revision",
        ContentEntry: "RepositoryContent::Entry",
        ContentBlob: "RepositoryContent::Blob",
        ContentChange: "RepositoryContent::Change",
        ContentRef: "RepositoryContent::Ref",
        ContentCommit: "RepositoryContent::Commit",
        ContentCommitHistory: "RepositoryContent::CommitHistory",
        ContentDivergence: "RepositoryContent::Divergence",
        ContentError: "RepositoryContent::Error",
        ContentNotFound: "RepositoryContent::NotFound",
        ContentUnavailable: "RepositoryContent::Unavailable",
        ContentUnknownRevision: "RepositoryContent::UnknownRevision",
        ContentUnsupported: "RepositoryContent::Unsupported",
        ContentTooLarge: "RepositoryContent::TooLarge",
        ContentTruncated: "RepositoryContent::Truncated",
        ExecutionBackendBase: "Execution::Backend",
        LocalExecution: "Execution::Local",
        SpeechToTextBase: "ChatSpeechToText::Providers::Base",
        SpeechToTextInvalidAudio: "ChatSpeechToText::Providers::InvalidAudio",
        SpeechToTextStreamingDelta: "ChatSpeechToText::Providers::StreamingDelta",
        SpeechToTextError: "ChatSpeechToText::Providers::TranscriptionError",
        SpeechToTextResult: "ChatSpeechToText::Providers::TranscriptionResult",
        SpeechToTextTimeout: "ChatSpeechToText::Providers::TranscriptionTimeout",
        SpeechToTextUnavailable: "ChatSpeechToText::Providers::TranscriptionUnavailable",
        SpeechToTextTelemetry: "ChatSpeechToText::Telemetry",
        McpToolSet: "Syrus::Plugin::McpToolSet",
        ChatMcpToolSet: "Syrus::Plugin::ChatMcpToolSet",
        SidebarPage: "Syrus::Plugin::SidebarPage",
        UiSlot: "Syrus::Plugin::UiSlot",
        ChatIdentityProvider: "Syrus::Plugin::ChatIdentityProvider",
        ChatPayloadContributor: "Syrus::Plugin::ChatPayloadContributor",
        ChatTurnFinalizer: "Syrus::Plugin::ChatTurnFinalizer",
        ChatTurnLifecycle: "Syrus::Plugin::ChatTurnLifecycle",
        ChatTurnOrientation: "Syrus::Plugin::ChatTurnOrientation",
        ChatWorkspaceLifecycle: "Syrus::Plugin::ChatWorkspaceLifecycle",
        DiffReviewAnnotationProvider: "Syrus::Plugin::DiffReviewAnnotationProvider",
        JobVisibilityRestriction: "Syrus::Plugin::JobVisibilityRestriction",
        McpRunContextContributor: "Syrus::Plugin::McpRunContextContributor",
        PostImplementationReviewProvider: "Syrus::Plugin::PostImplementationReviewProvider",
        RepositoryConfiguration: "Syrus::Plugin::RepositoryConfiguration",
        RepositoryFilter: "Syrus::Plugin::RepositoryFilter",
        RetentionPolicy: "Syrus::Plugin::RetentionPolicy",
        ReviewContextContributor: "Syrus::Plugin::ReviewContextContributor",
        ReviewGate: "Syrus::Plugin::ReviewGate",
        ReviewPresentationContributor: "Syrus::Plugin::ReviewPresentationContributor",
        ReviewerTargetProvider: "Syrus::Plugin::ReviewerTargetProvider",
        ContentReader: "RepositoryContent",
        PathJail: "Syrus::PathJail",
        PathJailEscape: "Syrus::PathJail::PathEscape",
        SyrusYmlParseError: "SyrusYml::ParseError",
        AgentRole: "AgentRole",
        ReviewerTargetResolver: "ReviewerTargets",
        ReviewerTargetRequired: "ReviewerTargets::TargetRequired",
        ReviewerTargetUnavailable: "ReviewerTargets::TargetUnavailable",
        GateResult: "WorkUnits::GateResult",
        HandleRegistry: "HandleRegistry"
      }.freeze

      ALIAS_CONTRACTS = {
        PluginApi: [ "Declares and installs plugin manifests; Definition internals are not promised.", %w[syrus_plugin syrus_plugin_definition register! enabled?] ],
        AgentProvider: [ "Supplies the optional agent-provider class hooks that plugins may override; invocation orchestration and undeclared provider methods are not promised.", %w[mcp_tool_name evidence_reset_at false_positive_evidence? suppress_usage_limit_run? ignore_model_for_positive_evidence? usage_signal_account_id usage_snapshot usage_status usage_observed_at availability_evidence_observed_at usage_windows configured_for_user? credential_attributes available_models] ],
        AdminPage: [ "Supplies admin navigation and route metadata; host navigation implementation details are not promised.", %w[admin_pages] ],
        Callbacks: [ "Defines plugin lifecycle callbacks; callback scheduling and storage are not promised.", %w[on_boot on_shutdown on_enable on_disable on_tick on_metrics_scrape effect] ],
        PermissionProvider: [ "Declares plugin permission capabilities and scopes; core authorization storage is not promised.", %w[register_authorization_adapter register_resource_scope register_capability register_permission_preset migrate_permission_scope retire_permission_identifier] ],
        RepositoryContentProvider: [ "Supplies the immutable repository-content provider contract; cache and fallback orchestration are not promised.", %w[provider_key display_name role available_for? build resolve tree children read changes refs relation history commits tree_sha divergence] ],
        CliCommandHandler: [ "Bases server-backed plugin CLI handlers; transport internals are not promised.", %w[call table text raw_text json] ],
        BackupArtifactSource: [ "Defines the sealed backup-artifact source operations plugins may provide; replication orchestration is not promised.", %w[list describe open checksum pin release_pin record_replication] ],
        BackupDestination: [ "Defines offsite backup destination operations plugins may provide; credential storage and replication orchestration are not promised.", %w[upload verify delete materialize_local health] ],
        SystemAlertProvider: [ "Defines the system-alert contribution plugins may provide; alert aggregation and delivery are not promised.", %w[system_alerts] ],
        ExternalReviewer: [ "Defines provisional external-review dispatch, refresh, and cancellation operations; lifecycle orchestration and storage are not promised.", %w[provider_key display_name capabilities available_for? submit refresh cancel] ],
        ExternalReviewContext: [ "Carries immutable public review inputs and host-supplied account/client facades; records, credentials, and GitHub internals are not exposed.", %w[new repository job pull_request base_sha head_sha diff_review_version trigger rule links summary evidence connected_account client external_id idempotency_key] ],
        ExternalReviewResult: [ "Normalizes external-review outcomes and provider response data; persistence, retry scheduling, and publication policy are not promised.", %w[new accepted completed declined retryable_failure terminal_failure outcome external_id idempotency_key retry_after artifacts feedback verdict publication metadata retryable? terminal?] ],
        ExternalReviewArtifact: [ "Describes a typed external-review artifact without transferring artifact-storage ownership to providers.", %w[new kind name content_type location metadata] ],
        InvocationResult: [ "Carries an agent or chat invocation result; invocation-engine internals are not promised.", %w[new turns exit_status timed_out is_error outcome final_text session_id transcript_jsonl transcript_path cost_usd input_tokens output_tokens success?] ],
        ToolContext: [ "Exposes immutable authorization and request scope to tool handlers; construction and mutation are not promised.", %w[surface role user repository job workflow run chat_session run? chat? interactive from_server_context from_run] ],
        Current: [ "Exposes the request-local authenticated user; assignment and other current attributes are not promised.", %w[user api_user] ],
        Record: [ "Bases plugin-owned records in the primary database; private core helpers are not promised.", %w[belongs_to has_many transaction] ],
        BackgroundJob: [ "Bases plugin-owned Active Job classes; core queue topology and callbacks are not promised.", %w[queue_as operational_log_context] ],
        McpTools: [ "Provides database-connection and MCP response helpers; core tool implementations are not promised.", %w[with_database_connection success invalid unauthorized not_authorized truncate_text run_from_context utf8 write_log] ],
        AdminController: [ "Bases admin-token plugin API controllers; core filters and implementation details are not promised.", %w[params render] ],
        AppController: [ "Bases authenticated plugin application API controllers; core filters are not promised.", %w[params render] ],
        AppAdminController: [ "Bases authenticated plugin admin API controllers; core filters are not promised.", %w[params render] ],
        ProcessRunner: [ "Runs managed plugin subprocesses with host cancellation and confinement; backend internals are not promised.", %w[new run capture start mounts agent_mounts probe_mounts forwarded_env] ],
        OperationalLogging: [ "Emits structured plugin diagnostic events; subscribers and storage are not promised.", %w[ingest] ],
        PerformanceLogging: [ "Times named plugin phases; event storage and thresholds are not promised.", %w[phase report_duration] ],
        Metrics: [ "Fetches plugin-declared metrics instruments; registry mutation and core declarations are not promised.", %w[counter gauge histogram] ],
        PluginRegistry: [ "Registers manifests and reads extension providers; reset, health, and cache internals are not promised.", %w[register providers_for capability_providers providers_with_owner_for extension_point?] ],
        PluginInvocation: [ "Contains plugin provider failures behind the shared runtime health boundary; runtime-health internals are not promised.", %w[call] ],
        CapabilityValidationError: [ "Reports a deliberate caller-visible capability validation problem without counting it as a provider crash.", %w[new code details message] ],
        EcosystemGraderCoverage: [ "Shares the supported coverage-phase decision used by Ecosystem grader-type providers.", %w[coverage_for_phases?] ],
        EcosystemPreparePlan: [ "Carries one ecosystem's immutable repository detection and preparation answer.", %w[new detected detected? commands version_file span_labels label] ],
        EcosystemDependencyAuditPlan: [ "Carries one ecosystem's immutable dependency-audit lockfiles and command.", %w[new lockfiles command label] ],
        Toolkit: [ "Discovers enabled Toolkit-family providers for plugin-owned cross-tool composition.", %w[chat_tool_sets chat_tool_set_for] ],
        GraderStep: [ "Describes one grader step an ecosystem grader-type provider returns; configuration parsing and plan expansion are not promised.", %w[new name display_name run ci phases description required timeout_minutes when_files_changed junit_output failures base_retry deps metadata capabilities resources] ],
        GraderBaseRetry: [ "Names how a grader reruns against the base branch (strategy and optional command); retry orchestration is not promised.", %w[new strategy command] ],
        GraderDefaults: [ "Supplies the default grading phases and the grader timeout ceiling that ecosystem grader types share; the values may change between releases.", %w[default_phases max_timeout_minutes] ],
        GraderResourceRequest: [ "Declares the CPU and memory a grader can productively use; grant resolution against the host is not promised.", %w[new parse ALL cpu cpu_min memory_bytes empty?] ],
        GraderExecutionCapabilities: [ "Normalizes the execution capabilities (os, arch, toolchain, runtime) a grader target requires; worker routing is not promised.", %w[new to_h] ],
        TestRunResult: [ "Carries one parsed test-suite run returned by a test-result parser; the XML parser that produces it is not promised.", %w[new] ],
        TestCaseResult: [ "Carries one parsed test case inside a TestRunResult; the XML parser that produces it is not promised.", %w[new] ],
        CoverageParseResult: [ "Carries a parsed coverage report (raw data and line percentage) returned by a coverage analyzer; the report parsers are not promised.", %w[new raw lines_pct] ],
        WorkflowWorkspace: [ "Resolves a workflow's checkout path and base ref; cloning, locking, and cleanup are not promised.", %w[new path_for base_ref data_root agent_home_for REQUIRED_BRANCH_ARTIFACT] ],
        GitRunner: [ "Runs git inside a workflow workspace and reports failures as GitError; command construction and logging are not promised.", %w[new run redact GitError] ],
        CapabilityDescriptor: [ "Builds the permission capability descriptor for a plugin MCP tool definition; descriptor storage and evaluation are not promised.", %w[for_plugin_definition] ],
        ExecutionBackend: [ "Marks a class as an alternate execution backend plugins may provide; request routing and fail-closed policy are not promised.", %w[available_for?] ],
        InputSource: [ "Defines the input-source contract plugins implement to ingest external work items; polling orchestration is not promised.", %w[] ],
        SourceControlProvider: [ "Defines the source-control operations a git-host plugin supplies; callers and orchestration are not promised.", %w[provider_key display_name available_for? client_for] ],
        SpeechToTextProvider: [ "Marks a class as a speech-to-text provider plugins may contribute; provider selection is not promised.", %w[provider_key display_name available? build] ],
        PlatformDelivery: [ "Defines outbound chat-platform delivery plugins may provide; routing and retry policy are not promised.", %w[platform_key connector_job_class platform_config_class deliver] ],
        PurgeContributor: [ "Lets a plugin remove its own external resources when it is purged; purge ordering is not promised.", %w[purge_report purge!] ],
        WorkerCapabilityProbe: [ "Lets a plugin advertise worker capabilities; capability routing is not promised.", %w[capability_probes] ],
        WorkflowArtifactContributor: [ "Lets a plugin contribute workflow artifacts; artifact storage is not promised.", %w[for_job] ],
        WorkspaceGitTransport: [ "Defines how a plugin supplies git transport for a workflow workspace; clone orchestration is not promised.", %w[available_for? build url env register!] ],
        AgenticConnection: [ "Shared agentic-access gating for plugin-owned connection records; connection storage is not promised.", %w[find_agentic! find_agentic_with_write_access! require_write_access! agentic_credential_usable_by?] ],
        GatedToolSet: [ "Bases tool sets exposed only when agentic access is enabled; gating internals are not promised.", %w[coworker_grant coworker_grants gated_by gated? available_for? available_for_context? available_for_coworker? coworker_discovery_state tool_classes find_tool_class tool_definitions] ],
        ContentSource: [ "Describes where a repository-content provider answered from; cache internals are not promised.", %w[new vcs url username password expires_at] ],
        ContentRevision: [ "Immutable repository revision value returned by content providers.", %w[new id ref observed_at] ],
        ContentEntry: [ "Tree-entry value returned by content providers.", %w[new path type size content_id] ],
        ContentBlob: [ "File-content value returned by content providers.", %w[new path bytes size truncated content_id] ],
        ContentChange: [ "Changed-file value returned by content providers.", %w[new path status previous_path patch additions deletions patch_status patch_bytes] ],
        ContentRef: [ "Named ref (tag or branch) value returned by content providers.", %w[new name revision_id observed_at] ],
        ContentCommit: [ "Commit value returned by content providers.", %w[new sha message authored_at] ],
        ContentCommitHistory: [ "Commit-range value returned by content providers.", %w[new commits merge_base_id] ],
        ContentDivergence: [ "Ahead/behind counts returned by content providers.", %w[new ahead behind] ],
        ContentError: [ "Base error for repository-content failures; providers raise its subclasses.", %w[new message] ],
        ContentNotFound: [ "A final answer that the requested path does not exist at the revision.", %w[new message] ],
        ContentUnavailable: [ "The provider cannot answer right now; callers fall through to the next provider and must not treat it as missing.", %w[new message] ],
        ContentUnknownRevision: [ "The provider does not know the requested revision; callers fall through to the next provider.", %w[new message] ],
        ContentUnsupported: [ "The provider does not support the requested operation; callers fall through to the next provider.", %w[new message] ],
        ContentTooLarge: [ "The requested content exceeds what the provider will return.", %w[new message] ],
        ContentTruncated: [ "Carries a partial answer that only display code may use.", %w[new message] ],
        ExecutionBackendBase: [ "Bases an alternate execution backend; request routing is not promised.", %w[run] ],
        LocalExecution: [ "The default local execution backend an alternate backend may delegate to.", %w[new run] ],
        SpeechToTextBase: [ "Bases speech-to-text providers; provider selection is not promised.", %w[new] ],
        SpeechToTextInvalidAudio: [ "Raised when audio cannot be transcribed because it is invalid.", %w[new message] ],
        SpeechToTextStreamingDelta: [ "One incremental streaming transcription update.", %w[new text final] ],
        SpeechToTextError: [ "Base error for transcription failures.", %w[new message] ],
        SpeechToTextResult: [ "A completed transcription result.", %w[new] ],
        SpeechToTextTimeout: [ "Raised when transcription times out.", %w[new message] ],
        SpeechToTextUnavailable: [ "Raised when a transcription backend is unavailable.", %w[new message] ],
        SpeechToTextTelemetry: [ "Shared transcription telemetry helpers; log fields may change between releases.", %w[log duration_ms monotonic_time safe_error] ],
        McpToolSet: [ "Marks a class as a workflow MCP tool set a plugin may contribute; the tool-set implementation must define .tool_definitions, .available_for? and #handle, and may define .available_for_context?; registration, gating and dispatch are not promised.", %w[tool_definitions available_for? available_for_context? handle] ],
        ChatMcpToolSet: [ "Marks a class as a chat MCP tool set a plugin may contribute; the implementation must define .tool_definitions(tier:), .available_for?(chat_session, tier:) and #handle; tool policy flags other than the documented definition keys are not promised.", %w[tool_definitions available_for? handle] ],
        SidebarPage: [ "Marks a provider of plugin sidebar pages; the host navigation and routing around the returned metadata are not promised.", %w[sidebar_pages] ],
        UiSlot: [ "Marks a provider of panels rendered inside an existing core page; slot rendering, caching and ordering are not promised.", %w[ui_slots SLOTS valid_slot?] ],
        ChatIdentityProvider: [ "Lets a plugin own participant or agent identities on generic chat surfaces; every hook is optional and defaults to declining, and envelope validation is not promised.", %w[chat_identities chat_turn_identity chat_turn_trigger chat_search_ownership chat_group_ownership chat_message_presentations chat_status_contributions] ],
        ChatPayloadContributor: [ "Lets a plugin add its own keys, paths and counts to the chat payload; payload assembly and the context keys beyond :params and :ssl are not promised.", %w[chat_payload chat_message_payload chat_payload_paths chat_payload_counts] ],
        ChatTurnFinalizer: [ "Lets a plugin run work after an agent turn and before the chat releases its serialization lock; the surrounding turn loop is not promised.", %w[after_chat_turn] ],
        ChatTurnLifecycle: [ "Lets an optional plugin own admission and execution context for a chat turn; the including class answers .applies_to?(chat_session:, user_message:) and, per turn, #admission, #context, #isolated_workspace? and #synchronize; the generic invocation loop is not promised.", %w[applies_to? admission context isolated_workspace? synchronize] ],
        ChatTurnOrientation: [ "Lets a plugin take over how one chat turn opens, based on the message that triggered it; ordering among providers is not promised.", %w[chat_turn_orientation] ],
        ChatWorkspaceLifecycle: [ "Lets an optional plugin provide a durable checkout around a chat turn; the including class answers .applies_to?(chat_session:) and implements #prepare!(chat_session:) and #finalize!(chat_session:); workspace allocation is not promised.", %w[applies_to? prepare! finalize!] ],
        DiffReviewAnnotationProvider: [ "Lets a plugin enrich the Job review tab with annotations, panels, actions and counts; normalization of the returned payload is not promised.", %w[review_annotations] ],
        JobVisibilityRestriction: [ "Restricts which Jobs of one origin a user may see; how the host combines the returned origin ids with repository visibility is not promised.", %w[origin_key visible_origin_ids] ],
        McpRunContextContributor: [ "Adds plugin-owned authorization attributes to workflow MCP runs; the receiving context's construction is not promised.", %w[context_attributes] ],
        PostImplementationReviewProvider: [ "Lets a plugin request a best-effort agentic pass after an implementation workflow produced its final diff; the host step that runs it is not promised.", %w[review_needed? prompt_sections required_mcp_tools] ],
        RepositoryConfiguration: [ "Defines one namespaced .syrus.yml contribution a plugin owns; parsing, storage and project resolution are not promised.", %w[legacy_keys overlay affected_project?] ],
        RepositoryFilter: [ "Narrows repository relations on general discovery surfaces; direct repository access and authorization are separate and not promised here.", %w[apply] ],
        RetentionPolicy: [ "Lets a plugin contribute retention definitions for the tables it owns; the retention registry and pruner are not promised.", %w[retention_definitions] ],
        ReviewContextContributor: [ "Supplies restricted context and post-verdict persistence for an opaque reviewer target; the review lifecycle is not promised.", %w[tool_set tool_capability operator_links retention tombstone] ],
        ReviewGate: [ "Contributes a review loop to a host workflow; the host owns ordering and loop mechanics.", %w[review_gates job_detail_fields SLOTS] ],
        ReviewPresentationContributor: [ "Contributes metadata-only UI and audit renderers for review targets; frontend loading is not promised.", %w[target_editors evidence_renderers audit_renderers settings_summaries translation_namespaces] ],
        ReviewerTargetProvider: [ "Defines the reviewer-target type a plugin owns: its options, resolution, availability, uniqueness and audit snapshot; target persistence is not promised.", %w[target_type options resolve available? uniqueness_key audit_snapshot] ],
        ContentReader: [ "Resolves the repository-content reader for a repository; the provider chain and cache behind it are not promised, and only the content value and error facades are public beyond it.", %w[for] ],
        PathJail: [ "Resolves a relative path beneath a root directory and refuses anything that escapes it.", %w[resolve!] ],
        PathJailEscape: [ "Raised when a path resolves outside its root; carries the reason, relative path and root.", %w[new reason relative_path root message] ],
        SyrusYmlParseError: [ "Raised by a plugin's repository-configuration parser when its .syrus.yml contribution is invalid.", %w[new message] ],
        AgentRole: [ "Names the agent roles a plugin may pass as the role of a tool context or workflow run; only the listed role identifiers are promised, not the role groupings or authorization derived from them.", %w[AGENT_INSIGHT CHAT_PLANNER COWORKER COWORKER_CHAT WORKFLOW_COWORKER_REVIEWER WORKFLOW_MANUAL WORKFLOW_ROLES] ],
        ReviewerTargetResolver: [ "Resolves a reviewer-target reference through the enabled providers; provider selection and failure containment are not promised.", %w[resolve] ],
        ReviewerTargetRequired: [ "Raised when a review requires a reviewer target and none was pinned.", %w[new message] ],
        ReviewerTargetUnavailable: [ "Raised when a pinned reviewer target cannot currently be resolved.", %w[new message] ],
        GateResult: [ "Value a plugin gate returns to let a start proceed or to hold it, with an optional reason, retry time and details; the scheduling that consumes it is not promised.", %w[pass block blocked? pass? reason retry_at details] ],
        HandleRegistry: [ "Claims, renames and releases the unique handles that address users and coworkers; handle storage is not promised.", %w[normalize claim! rename! release!] ]
      }.freeze

      DOMAIN_CONTRACTS = {
        Job: [ "Reads a job's identity, state, title, repository, owner, and workflows through find and visibility-scoped lookups; transitions, persistence, callbacks, and other associations are not promised.", %w[find visible_to accessible_to id state title repository user workflows] ],
        Repository: [ "Reads repository identity, owner/name, archival state, and jobs through find and access-scoped lookups; credentials, synchronization, persistence, and other associations are not promised.", %w[find active accessible_to writable_by id owner name archived_at jobs] ],
        User: [ "Reads user identity, handle, display name, administrator status, repositories, and jobs through find; credentials, preferences, persistence, and other associations are not promised.", %w[find id handle display_name admin? repositories jobs] ],
        Run: [ "Reads a run's identity, state, workflow, and job through find; dispatch, lifecycle transitions, persistence, and other associations are not promised.", %w[find id state workflow job] ],
        Workflow: [ "Reads a workflow's identity, state, job, and runs through find; scheduling, transitions, repair, persistence, and other associations are not promised.", %w[find id state job runs] ],
        ChatSession: [ "Reads a chat session's identity, title, owner, and repository through find; turns, broadcasts, artifacts, persistence, and other associations are not promised.", %w[find id title user repository] ]
      }.freeze

      SERVICE_CONTRACTS = {
        ChatTitles: [ "Queues automatic title generation for a chat; job implementation and queue details are not promised.", %w[enqueue] ],
        DiskUsage: [ "Reads filesystem capacity snapshots for plugin-managed storage; caching and host health policy are not promised.", %w[read] ],
        AgentRuntime: [ "Reads the shared timeout, turn, event-size, and environment-forwarding defaults agent-provider plugins use when launching an agent CLI; the invocation engine and the values themselves may change between releases.", %w[default_timeout_seconds silent_timeout_seconds default_max_turns max_event_bytes forwarded_env_keys oversized_event_handler] ],
        SystemAlert: [ "Builds a host-compatible system alert value; aggregation, persistence, and delivery are not promised.", %w[build] ]
      }.freeze

      STATIC_CONTRACTS = {
        ApplicationRecord: [ "Stable Active Record base for plugin-owned models. Plugins may inherit from it and set their own table name; host persistence internals are not public.", %w[abstract_class table_name table_name=] ]
      }.freeze

      class << self
        def install!
          install_aliases!
          replace_contracts!
          register_contracts(ALIAS_CONTRACTS, qualify: true)
          register_contracts(DOMAIN_CONTRACTS)
          register_contracts(SERVICE_CONTRACTS)
          register_contracts(STATIC_CONTRACTS)
        end

        private

        def install_aliases!
          ALIASES.each do |name, target_name|
            Host.send(:remove_const, name) if Host.const_defined?(name, false)
            Host.const_set(name, target_name.constantize)
          end
        end

        def replace_contracts!
          managed_names = (ALIAS_CONTRACTS.keys + DOMAIN_CONTRACTS.keys + SERVICE_CONTRACTS.keys + STATIC_CONTRACTS.keys).map { |name| "Syrus::Host::#{name}" }
          Host.apis.reject! { |api| managed_names.include?(api.name) }
        end

        def register_contracts(contracts, qualify: false)
          contracts.each do |name, (summary, members)|
            summary = "#{summary} Only the listed members are supported." if qualify
            Host.api("Syrus::Host::#{name}", since: "0.1.16", summary:, members:)
          end
        end
      end
    end
  end
end
