require "build_cache/version"
require "build_cache/engine"

module BuildCache
  def self.register!
    Syrus::PluginRegistry.register(
      name:            "build_cache",
      display_name:    "Build Cache",
      version:         BuildCache::VERSION,
      default_enabled: true,
      disableable:     true,
      category:        "tooling",
      description:     "Shared sccache compiler cache: forwards its credentials into step subprocesses, records hit/miss stats, and offers audited bucket clears.",
      long_description: "Build Cache wires the shared sccache compiler cache into the subprocesses workflow steps run, captures a hit/miss snapshot after each command, and gives operators an audited way to inspect and clear the bucket.\n\nIt is a no-op until SCCACHE_BUCKET is configured, which is a supported state: sccache falls back to a local per-worker cache on its own. Clearing the bucket is expensive for build times, so it requires an explicit reason and a separate confirmation step.",
      homepage:        "https://github.com/tkadauke/syrus",
      icon_url:        "/plugin-icons/spqr_eagle.svg",
      author:          "Thomas Kadauke",
      config_schema: [
        { key: "bucket", label: "Cache bucket", type: :secret_env, env_var: "SCCACHE_BUCKET",
          required: false, description: "S3-compatible bucket for the shared compiler cache. Set in .env." }
      ],
      frontend: {
        routes: { "build_cache/AdminBuildCache" => "app/frontend/routes/AdminBuildCache.tsx" },
        ui_slots: { "build_cache/SccacheCard" => "app/frontend/ui_slots/SccacheCard.tsx" },
        i18n: [ "app/frontend/i18n/locales/*/build_cache.json" ]
      },
      routes: [
        { verb: "GET",  path: "/api/v1/app/admin/build_cache", controller: "api/v1/app/admin/build_cache#show" },
        { verb: "POST", path: "/api/v1/app/admin/build_cache/clear_requests", controller: "api/v1/app/admin/build_cache#create_clear_request" },
        { verb: "POST", path: "/api/v1/app/admin/build_cache/clear_requests/:id/confirm", controller: "api/v1/app/admin/build_cache#confirm_clear_request" },
        { verb: "POST", path: "/api/v1/app/admin/build_cache/clear_requests/:id/cancel", controller: "api/v1/app/admin/build_cache#cancel_clear_request" },
        { verb: "GET",  path: "/api/v1/admin/build_cache", controller: "api/v1/admin/build_cache#show" },
        { verb: "GET",  path: "/admin/build_cache", controller: "spa#show" }
      ],
      provides: {
        admin_page:        BuildCache::AdminPages,
        ui_slot:           BuildCache::UiSlots,
        domain_subscriber: BuildCache::Subscribers,
        step_environment:  BuildCache::StepEnvironment
      }
    )
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "build_cache" && manifest.enabled? }
  end
end
