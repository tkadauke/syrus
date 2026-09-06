require "build_cache/data_cleanup"

module BuildCache
  extend Syrus::PluginApi

  syrus_plugin "build_cache" do
    display_name "Build Cache"
    description "Shared sccache compiler cache: forwards its credentials into step subprocesses, records hit/miss stats, and offers audited bucket clears."
    long_description "Build Cache wires the shared sccache compiler cache into the subprocesses workflow steps run, captures a hit/miss snapshot after each command, and gives operators an audited way to inspect and clear the bucket.\n\nIt is a no-op until SCCACHE_BUCKET is configured, which is a supported state: sccache falls back to a local per-worker cache on its own. Clearing the bucket is expensive for build times, so it requires an explicit reason and a separate confirmation step."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/build_cache.svg"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled true
    disableable true
    config_schema [
        { key: "bucket", label: "Cache bucket", type: :secret_env, env_var: "SCCACHE_BUCKET",
          required: false, description: "S3-compatible bucket for the shared compiler cache. Set in .env." }
      ]
    provides admin_page: "BuildCache::AdminPages",
             ui_slot: "BuildCache::UiSlots",
             domain_subscriber: "BuildCache::Subscribers",
             step_environment: "BuildCache::StepEnvironment"
    route :get, "/api/v1/app/admin/build_cache", to: "api/v1/app/admin/build_cache#show"
    route :post, "/api/v1/app/admin/build_cache/clear_requests", to: "api/v1/app/admin/build_cache#create_clear_request"
    route :post, "/api/v1/app/admin/build_cache/clear_requests/:id/confirm", to: "api/v1/app/admin/build_cache#confirm_clear_request"
    route :post, "/api/v1/app/admin/build_cache/clear_requests/:id/cancel", to: "api/v1/app/admin/build_cache#cancel_clear_request"
    route :get, "/api/v1/admin/build_cache", to: "api/v1/admin/build_cache#show"
    route :get, "/api/v1/app/repositories/:id/build_cache_settings", to: "api/v1/app/build_cache_repository_settings#show"
    route :patch, "/api/v1/app/repositories/:id/build_cache_settings", to: "api/v1/app/build_cache_repository_settings#update"
    route :get, "/admin/build_cache", to: "spa#show"
    frontend routes: { "build_cache/AdminBuildCache" => "app/frontend/routes/AdminBuildCache.tsx" },
        ui_slots: { "build_cache/SccacheCard" => "app/frontend/ui_slots/SccacheCard.tsx" },
        i18n: [ "app/frontend/i18n/locales/*/build_cache.json" ]

    # The per-repository basedirs_safe row outlives the plugin being
    # disabled, and still has to go when its repository does.
    always do |scope|
      BuildCache::DataCleanup.install_into(scope)
    end
  end
end
