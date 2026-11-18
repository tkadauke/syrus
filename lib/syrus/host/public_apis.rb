require "syrus/host"
%w[
  agent_provider callbacks chat_mcp_tool_set chat_provider domain_subscriber
  input_source mcp_tool_set permission_provider repository_content_provider
  workflow_kinds cli_command_handler
].each { |name| require "syrus/plugin/#{name}" }

module Syrus::Host::PublicApis
end

module Syrus
  module Host
    PUBLIC_API_ALIASES = {
      PluginApi: ::Syrus::PluginApi,
      AgentProvider: ::Syrus::Plugin::AgentProvider,
      Callbacks: ::Syrus::Plugin::Callbacks,
      ChatMcpToolSet: ::Syrus::Plugin::ChatMcpToolSet,
      ChatProvider: ::Syrus::Plugin::ChatProvider,
      DomainSubscriber: ::Syrus::Plugin::DomainSubscriber,
      InputSource: ::Syrus::Plugin::InputSource,
      McpToolSet: ::Syrus::Plugin::McpToolSet,
      PermissionProvider: ::Syrus::Plugin::PermissionProvider,
      RepositoryContentProvider: ::Syrus::Plugin::RepositoryContentProvider,
      WorkflowKinds: ::Syrus::Plugin::WorkflowKinds,
      CliCommandHandler: ::Syrus::Plugin::CliCommandHandler,
      InvocationResult: ::AgentInvocation::Result,
      ToolContext: ::McpToolContext,
      Current: ::Current,
      Record: ::ApplicationRecord,
      BackgroundJob: ::ApplicationJob,
      McpTools: ::Mcp::Tools,
      AdminController: ::Api::V1::Admin::BaseController,
      AppController: ::Api::V1::App::BaseController,
      AppAdminController: ::Api::V1::App::Admin::BaseController,
      ProcessRunner: ::ProcessRunner,
      OperationalLogging: ::OperationalLogging,
      PerformanceLogging: ::PerformanceLogging,
      Metrics: ::Syrus::Metrics,
      PluginRegistry: ::Syrus::PluginRegistry
    }.freeze

    PUBLIC_API_ALIASES.each { |name, target| const_set(name, target) }
  end
end

alias_contracts = {
  PluginApi: [ "Declares and installs plugin manifests; Definition internals are not promised.", %w[syrus_plugin syrus_plugin_definition register! enabled?] ],
  AgentProvider: [ "Defines the agent-provider extension contract; host orchestration internals are not promised.", [] ],
  Callbacks: [ "Defines plugin lifecycle callbacks; callback scheduling and storage are not promised.", %w[on_boot on_shutdown on_enable on_disable on_tick on_metrics_scrape effect] ],
  ChatMcpToolSet: [ "Defines chat MCP tool sets; core tool implementations and policy internals are not promised.", [] ],
  ChatProvider: [ "Defines interactive chat providers; host session orchestration is not promised.", [] ],
  DomainSubscriber: [ "Defines domain-event subscribers; delivery scheduling and event persistence are not promised.", [] ],
  InputSource: [ "Defines polling input sources; host polling orchestration is not promised.", [] ],
  McpToolSet: [ "Defines workflow MCP tool sets; core tool implementations are not promised.", [] ],
  PermissionProvider: [ "Declares plugin permission capabilities and scopes; core authorization storage is not promised.", %w[register_authorization_adapter register_resource_scope register_capability register_permission_preset migrate_permission_scope retire_permission_identifier] ],
  RepositoryContentProvider: [ "Defines immutable repository-content providers; cache and fallback orchestration are not promised.", %w[provider_key display_name role available_for? build resolve tree read changes refs relation history commits tree_sha divergence] ],
  WorkflowKinds: [ "Declares plugin workflow kinds; registry compilation and dispatch internals are not promised.", [] ],
  CliCommandHandler: [ "Bases server-backed plugin CLI handlers; transport internals are not promised.", %w[call table text raw_text json] ],
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
  PluginRegistry: [ "Registers manifests and reads extension providers; reset, health, and cache internals are not promised.", %w[register providers_for extension_point?] ]
}

alias_contracts.each do |name, (summary, members)|
  summary = "#{summary} Only the listed members are supported."
  Syrus::Host.api("Syrus::Host::#{name}", since: "0.1.16", summary:, members:)
end
