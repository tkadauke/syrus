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
    description "Owns main-branch health settings, current state, checks, and concern reports."
    default_enabled true
    disableable false

    provides callbacks: "MainBranchHealth::Callbacks",
             ui_slot: "MainBranchHealth::UiSlots"

    frontend bundle: "dist/frontend/plugin.js",
      ui_slots: { "main_branch_health/RepositorySettings" => "app/frontend/ui_slots/RepositorySettings.tsx" },
      i18n: [ "app/frontend/i18n/locales/*/main_branch_health.json" ]
  end
end
