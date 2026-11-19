require "coworkers/data_cleanup"
require "coworkers/chat_extension"
require "coworkers/search_extension"
require "coworkers/schedule_extension"

module Coworkers
  extend Syrus::PluginApi

  syrus_plugin "coworkers" do
    experimental true
    display_name "Coworkers"
    description "Persistent named agents with their own chats, capabilities, and workspace identity."
    long_description "Coworkers provides the data and policy foundation for persistent, user-owned agents. Each coworker has an instance-wide handle, explicit capability grants, a workspace remote, and one main chat plus optional side chats."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/coworkers.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled false
    disableable true
    depends_on [ "scheduled_tasks" ]
    optionally_depends_on [ "credential_store", "calendar", "metrics_dashboard" ]
    provides mentionable: "Coworkers::MentionableProvider",
             chat_identity_provider: "Coworkers::ChatIdentityProvider",
             callbacks: "Coworkers::Callbacks",
             mcp_run_context_contributor: "Coworkers::RunContextContributor",
             workflow_kinds: "Coworkers::WorkflowKinds",
             job_visibility_restriction: "Coworkers::JobVisibilityRestriction",
             repository_filter: "Coworkers::RepositoryFilter",
             chat_prompt_injector: "Coworkers::PromptSection",
             chat_turn_orientation: "Coworkers::MessageReply",
             chat_workspace_lifecycle: "Coworkers::ChatWorkspaceLifecycle",
             chat_turn_lifecycle: "Coworkers::ChatTurnLifecycle",
             sidebar_page: "Coworkers::SidebarPages",
             chat_payload_contributor: "Coworkers::PayloadContributor",
             chat_turn_finalizer: [ "Coworkers::HomeBranchPersistence", "Coworkers::MessageReply" ],
             chat_mcp_tool_set: "Coworkers::ChatToolSet",
             reviewer_target_provider: "Coworkers::ReviewerTargetProvider",
             review_context_contributor: "Coworkers::ReviewContextContributor",
             review_presentation_contributor: "Coworkers::ReviewPresentationContributor",
             repository_configuration: "Coworkers::RepositoryConfiguration",
             review_gate: "Coworkers::ReviewGate",
             mcp_tool_set: "Coworkers::ReviewToolSet",
             retention_policy: "Coworkers::ReviewContextRetentionPolicy",
             "metrics_dashboard:tab" => "Coworkers::MetricsDashboardTabs",
             "calendar:event_source" => "Coworkers::CalendarEventSource"
    tick_interval 5.minutes
    route :get, "/api/v1/app/coworkers", to: "api/v1/app/coworkers#index"
    route :get, "/api/v1/app/coworkers/options", to: "api/v1/app/coworkers#options"
    route :post, "/api/v1/app/coworkers", to: "api/v1/app/coworkers#create"
    route :post, "/api/v1/app/coworkers/test_remote", to: "api/v1/app/coworkers#test_remote"
    route :post, "/api/v1/app/coworkers/provisioning_attempts/:attempt_id/retry", to: "api/v1/app/coworkers#retry_provisioning_cleanup"
    route :post, "/api/v1/app/coworkers/provisioning_attempts/:attempt_id/acknowledge", to: "api/v1/app/coworkers#acknowledge_provisioning_cleanup"
    route :get, "/api/v1/app/coworkers/sidebar_badge", to: "api/v1/app/coworkers#sidebar_badge"
    route :get, "/api/v1/app/coworkers/:id/approvals", to: "api/v1/app/coworkers#approvals"
    route :post, "/api/v1/app/coworkers/:id/approvals/:approval_id/approve", to: "api/v1/app/coworkers#approve"
    route :post, "/api/v1/app/coworkers/:id/approvals/:approval_id/reject", to: "api/v1/app/coworkers#reject"
    route :get, "/api/v1/app/coworkers/:id", to: "api/v1/app/coworkers#show"
    route :get, "/api/v1/app/coworkers/:id/profile", to: "api/v1/app/coworkers#profile"
    route :get, "/api/v1/app/coworkers/:id/chats", to: "api/v1/app/coworkers#chats"
    route :get, "/api/v1/app/coworkers/:id/conversation_index", to: "api/v1/app/coworkers#conversation_index"
    route :get, "/api/v1/app/coworkers/:id/capabilities", to: "api/v1/app/coworkers#capabilities"
    route :get, "/api/v1/app/coworkers/:id/schedules", to: "api/v1/app/coworkers#schedules"
    route :patch, "/api/v1/app/coworkers/:id", to: "api/v1/app/coworkers#update"
    route :patch, "/api/v1/app/coworkers/:id/grants", to: "api/v1/app/coworkers#update_grant"
    route :delete, "/api/v1/app/coworkers/:id", to: "api/v1/app/coworkers#destroy"
    route :get, "/api/v1/app/coworkers/:id/memory", to: "api/v1/app/coworkers#memory"
    route :get, "/api/v1/app/coworkers/:id/workspace", to: "api/v1/app/coworkers#workspace"
    route :post, "/api/v1/app/coworkers/:id/workspace/retry", to: "api/v1/app/coworkers#retry_workspace_save"
    route :get, "/api/v1/app/coworkers/:id/activity", to: "api/v1/app/coworkers#activity"
    route :get, "/api/v1/app/coworkers/:id/review_contexts/:run_id", to: "api/v1/app/coworkers#review_context"
    route :get, "/api/v1/app/coworkers/:id/review_journal/:run_id", to: "api/v1/app/coworkers#review_journal"
    route :post, "/api/v1/app/coworkers/:id/schedules", to: "api/v1/app/coworkers#create_schedule"
    route :patch, "/api/v1/app/coworkers/:id/schedules/:schedule_id", to: "api/v1/app/coworkers#update_schedule"
    route :post, "/api/v1/app/coworkers/:id/schedules/:schedule_id/pause", to: "api/v1/app/coworkers#pause_schedule"
    route :post, "/api/v1/app/coworkers/:id/schedules/:schedule_id/resume", to: "api/v1/app/coworkers#resume_schedule"
    route :post, "/api/v1/app/coworkers/:id/schedules/:schedule_id/fire_now", to: "api/v1/app/coworkers#fire_schedule"
    route :post, "/api/v1/app/coworkers/:id/chats", to: "api/v1/app/coworkers#create_chat"
    route :post, "/api/v1/app/chats/:chat_id/agents/:id", to: "api/v1/app/coworkers#add_to_chat"
    route :patch, "/api/v1/app/chats/:chat_id/agents/:id", to: "api/v1/app/coworkers#update_chat_agent"
    route :delete, "/api/v1/app/chats/:chat_id/agents/:id", to: "api/v1/app/coworkers#remove_from_chat"
    frontend routes: {
          "coworkers/Coworkers" => "app/frontend/routes/Coworkers.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/coworkers.json" ]

    metrics do
      gauge :journaling_last_result_age_seconds, tags: %i[coworker],
            comment: "Seconds since the coworker's last journaled or dormant-skipped result"
      gauge :journaling_state, tags: %i[coworker state],
            comment: "Current journaling schedule state (the active state series has value 1)"
      gauge :journaling_last_result, tags: %i[coworker result],
            comment: "Last journaling result (the active result series has value 1)"
      gauge :journaling_consecutive_failures, tags: %i[coworker],
            comment: "Consecutive failures of the coworker's journaling schedule"
      gauge :unsaved_workspace_age_seconds, tags: %i[coworker],
            comment: "Age of the coworker's oldest unsaved workspace state, or zero"
      gauge :unsaved_workspace_attempts, tags: %i[coworker],
            comment: "Push attempts for the coworker's current unsaved workspace state"
      counter :workspace_push_failures_total, tags: %i[coworker kind], cluster: true,
              comment: "Workspace push failures by coworker and transient or permanent kind"
      counter :spend_usd_total, tags: %i[coworker source],
              comment: "Cumulative coworker spend in USD from chat or background runs"
      sampler MetricsSampler
    end

    always { |scope| Coworkers::DataCleanup.install_into(scope) }
    while_enabled do |scope|
      Coworkers::ChatExtension.install_into(scope)
      Coworkers::SearchExtension.install_into(scope)
      Coworkers::ScheduleExtension.install_into(scope)
    end
  end
end
