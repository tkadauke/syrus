require_relative "../app/models/main_branch_health/repository_accessors"
require_relative "../app/models/main_branch_health/app_setting_accessors"

ActiveSupport::Reloader.to_prepare do
  Repository.include(MainBranchHealth::RepositoryAccessors) unless Repository < MainBranchHealth::RepositoryAccessors
  AppSetting.include(MainBranchHealth::AppSettingAccessors) unless AppSetting < MainBranchHealth::AppSettingAccessors
end

module MainBranchHealth
  extend Syrus::PluginApi

  syrus_plugin "main_branch_health" do
    version "0.1.0"
    display_name "Main branch health"
    category "tooling"
    author "Thomas Kadauke"
    description "Checks main-branch health, pauses landing while main is broken, and repairs it."
    experimental false
    requires_syrus nil
    default_enabled true
    disableable true

    # Disableable. With the plugin off there is no gate, landing is not paused
    # and no health UI renders: core only consults the generic work_gate,
    # system_alert and repair_classifier points. Admin::PluginDisableGuard's
    # workflow_kind_blockers refuses the disable (with a reason) while a
    # main_grader or main_branch_repair workflow is still in flight.
    provides callbacks: "MainBranchHealth::Callbacks",
             retention_policy: "MainBranchHealth::RetentionPolicy",
             ui_slot: "MainBranchHealth::UiSlots",
             work_gate: "MainBranchHealthProvider",
             system_alert_provider: "MainBranchHealthProvider",
             repair_classifier: "MainBranchHealthProvider",
             base_branch_health: "MainBranchHealth::BaseBranchHealthProvider",
             adjudicator: "Adjudicators::ReportedMainConcern",
             workflow_kinds: "MainBranchHealth::WorkflowKinds",
             mcp_tool_set: "MainBranchHealth::McpToolSet",
             permission_provider: "MainBranchHealth::PermissionProvider",
             repo_page_tab: "MainBranchHealth::RepoPageTabs"
    tick_interval 5.minutes
    route :get, "/api/v1/app/repositories/:id/health_history", to: "api/v1/app/main_branch_health#health_history"
    route :post, "/api/v1/app/repositories/:id/run_main_branch_graders", to: "api/v1/app/main_branch_health#run_graders"
    route :post, "/api/v1/app/repositories/:id/repair_main_branch", to: "api/v1/app/main_branch_health#repair"
    route :post, "/api/v1/app/repositories/:id/check_ci_now", to: "api/v1/app/main_branch_health#check_ci_now"

    frontend bundle: "dist/frontend/plugin.js",
      routes: { "main_branch_health/RepositoryHealth" => "app/frontend/repo_tabs/RepositoryHealth.tsx" },
      ui_slots: {
        "main_branch_health/RepositorySettings" => "app/frontend/ui_slots/RepositorySettings.tsx",
        "main_branch_health/HealthBanners" => "app/frontend/ui_slots/HealthBanners.tsx"
      },
      i18n: [ "app/frontend/i18n/locales/*/main_branch_health.json" ]
  end
end
