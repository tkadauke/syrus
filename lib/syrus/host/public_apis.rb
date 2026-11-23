require "syrus/host"
require "syrus/host/backup_artifact_source"
require "syrus/host/backup_destination"
require "syrus/host/chat_titles"
require "syrus/host/disk_usage"
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
        VisualReviewProjects: "App::VisualReviewProjects",
        VisualReviewRuntimeTargets: "App::VisualReviewRuntimeTargets",
        PreviewPreparation: "PreviewPreparation",
        ReviewExecutionPolicy: "Steps::ReviewExecutionPolicy",
        GithubContentTrust: "Prompts::GithubContentTrust",
        RepositoryGlob: "RepositoryContent::Glob",
        ReviewFindingEvents: "ReviewFindingEvents",
        VisualDiffSubmission: "VisualDiffSubmission",
        VisualReviewEvidenceGuard: "VisualReviewEvidenceGuard",
        VisualReviewRuntimeSession: "VisualReviewRuntimeSession",
        FeedbackKind: "Workflow::FeedbackKind",
        TargetGraphCompiler: "TargetGraph::Compiler",
        BotIdentity: "BotIdentity",
        CodePathNormalizer: "CodeFacts::PathNormalizer",
        CoverageParsers: "CoverageAnalysis::Parsers",
        RetainedGraderCoverageOutputs: "RetainedGraderCoverageOutputs",
        SkillBase: "Skills::Base",
        StepFailed: "Steps::Base::StepFailed",
        WorkspaceContext: "Syrus::Plugin::Context::WorkspaceContext",
        PluginDispatch: "Syrus::Plugin::Dispatch"
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
        ToolContext: [ "Exposes immutable authorization and request scope to tool handlers; construction and mutation are not promised.", %w[surface role user repository job workflow run chat_session run? chat? interactive] ],
        Current: [ "Exposes the request-local authenticated user; assignment and other current attributes are not promised.", %w[user api_user] ],
        Record: [ "Bases plugin-owned records in the primary database; private core helpers are not promised.", %w[belongs_to has_many] ],
        BackgroundJob: [ "Bases plugin-owned Active Job classes; core queue topology and callbacks are not promised.", %w[queue_as operational_log_context] ],
        McpTools: [ "Provides database-connection and MCP response helpers; core tool implementations are not promised.", %w[with_database_connection success invalid] ],
        AdminController: [ "Bases admin-token plugin API controllers; core filters and implementation details are not promised.", %w[params render] ],
        AppController: [ "Bases authenticated plugin application API controllers; core filters are not promised.", %w[params render] ],
        AppAdminController: [ "Bases authenticated plugin admin API controllers; core filters are not promised.", %w[params render] ],
        ProcessRunner: [ "Runs managed plugin subprocesses with host cancellation and confinement; backend internals are not promised.", %w[new run capture start mounts forwarded_env] ],
        OperationalLogging: [ "Emits structured plugin diagnostic events; subscribers and storage are not promised.", %w[ingest] ],
        PerformanceLogging: [ "Times named plugin phases; event storage and thresholds are not promised.", %w[phase] ],
        Metrics: [ "Fetches plugin-declared metrics instruments; registry mutation and core declarations are not promised.", %w[counter gauge histogram] ],
        PluginRegistry: [ "Registers manifests and reads extension providers; reset, health, and cache internals are not promised.", %w[register providers_for capability_providers providers_with_owner_for extension_point?] ],
        PluginInvocation: [ "Contains plugin provider failures behind the shared runtime health boundary; runtime-health internals are not promised.", %w[call] ],
        CapabilityValidationError: [ "Reports a deliberate caller-visible capability validation problem without counting it as a provider crash.", %w[new code details message] ],
        EcosystemGraderCoverage: [ "Shares the supported coverage-phase decision used by Ecosystem grader-type providers.", %w[coverage_for_phases?] ],
        EcosystemPreparePlan: [ "Carries one ecosystem's immutable repository detection and preparation answer.", %w[new detected detected? commands version_file span_labels label] ],
        EcosystemDependencyAuditPlan: [ "Carries one ecosystem's immutable dependency-audit lockfiles and command.", %w[new lockfiles command label] ],
        VisualReviewProjects: [ "Resolves preview projects for a plugin-owned visual review step.", %w[call configured_when_files_changed] ],
        VisualReviewRuntimeTargets: [ "Resolves runtime targets for a plugin-owned visual review step.", %w[call] ],
        PreviewPreparation: [ "Prepares a preview for visual review.", %w[new call] ],
        ReviewExecutionPolicy: [ "Shares review-step skip and failure policy.", %w[] ],
        GithubContentTrust: [ "Shares the GitHub-content prompt trust boundary.", %w[] ],
        RepositoryGlob: [ "Matches repository paths against configured globs.", %w[match?] ],
        ReviewFindingEvents: [ "Records structured review findings.", %w[record] ],
        VisualDiffSubmission: [ "Coordinates deferred before/after visual comparisons.", %w[enqueue_deferred_for_visual_review] ],
        VisualReviewEvidenceGuard: [ "Validates visual review evidence.", %w[blocked_evidence_reason validate_visual_diff_after_artifacts] ],
        VisualReviewRuntimeSession: [ "Manages a visual review runtime session.", %w[new start! stop!] ],
        FeedbackKind: [ "Resolves feedback text for a workflow.", %w[for review_text] ],
        TargetGraphCompiler: [ "Compiles repository target configuration.", %w[compile] ],
        BotIdentity: [ "Recognizes comments authored by the Job's bot identity so a plugin can update only its own comments.", %w[for authored_github_comment?] ],
        CodePathNormalizer: [ "Normalizes tool-reported source paths to repository-relative paths.", %w[normalize] ],
        CoverageParsers: [ "Parses the shared lcov and Cobertura coverage report formats for the ecosystem coverage contract.", %w[for] ],
        RetainedGraderCoverageOutputs: [ "Reads the coverage files graders declared and the Run retained.", %w[for] ],
        SkillBase: [ "Bases plugin-contributed built-in skills; instruction rendering is not promised.", %w[definition] ],
        StepFailed: [ "Signals a deliberate, retry-classified step failure from a plugin-owned step.", %w[new message] ],
        WorkspaceContext: [ "Carries the workspace path and format hint passed to ecosystem capability providers.", %w[new] ],
        PluginDispatch: [ "Asks ecosystem capability providers a question and composes their answers.", %w[call] ]
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
