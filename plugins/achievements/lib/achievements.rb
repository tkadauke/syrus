require "achievements/data_cleanup"

module Achievements
  extend Syrus::PluginApi

  syrus_plugin "achievements" do
    experimental true
    requires_syrus nil
    display_name "Achievements"
    description "Instance milestones and per-user accomplishments with idempotent unlocks and per-user acknowledgments."
    long_description "Achievements owns a versioned definition registry, canonical unlock records, and per-user acknowledgments. Instance-scoped milestones unlock once per installation; user-scoped accomplishments unlock once per attributed user. Evaluation, presentation, and the development workbench are delivered separately."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true
    lifecycle callback_providers: "Achievements::Callbacks", domain_subscribers: "Achievements::Subscribers"
    route :get, "/api/v1/app/achievements", to: "api/v1/app/achievements#index"
    route :get, "/api/v1/app/achievements/pending", to: "api/v1/app/achievements#pending"
    route :post, "/api/v1/app/achievements/reset_acknowledgments", to: "api/v1/app/achievements#reset_acknowledgments"
    route :post, "/api/v1/app/achievements/:id/acknowledge", to: "api/v1/app/achievements#acknowledge"
    route :post, "/api/v1/app/achievements/:id/replay", to: "api/v1/app/achievements#replay"
    route :post, "/api/v1/app/admin/achievements/reset_acknowledgments", to: "api/v1/app/admin/achievements#reset_acknowledgments"

    # Disabling hides the feature but keeps the rows; they still have to go when
    # the user or subject they describe is destroyed, so this is `always`.
    always do |scope|
      Achievements::DataCleanup.install_into(scope)
    end
  end
end
