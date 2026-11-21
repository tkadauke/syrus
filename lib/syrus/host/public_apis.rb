require "syrus/host"
require "syrus/host/backup_artifact_source"
require "syrus/host/backup_destination"
require "syrus/host/chat_titles"
require "syrus/host/disk_usage"
require "syrus/host/system_alert"
require "syrus/host/system_alert_provider"
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
        PluginInvocation: "Syrus::PluginInvocation"
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
        PluginRegistry: [ "Registers manifests and reads extension providers; reset, health, and cache internals are not promised.", %w[register providers_for extension_point?] ],
        PluginInvocation: [ "Contains plugin provider failures behind the shared runtime health boundary; runtime-health internals are not promised.", %w[call] ]
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
