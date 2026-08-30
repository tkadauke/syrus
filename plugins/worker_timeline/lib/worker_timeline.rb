require "worker_timeline/version"
require "worker_timeline/engine"

module WorkerTimeline
  def self.register!
    Syrus::PluginRegistry.register(
      name:            "worker_timeline",
      display_name:    "Worker Timeline",
      version:         WorkerTimeline::VERSION,
      default_enabled: false,
      disableable:     true,
      category:        "observability",
      description:     "Multi-lane worker activity timeline: one lane per durable worker process role, with Job/Workflow spans over time.",
      long_description: "Worker Timeline visualizes overlapping Syrus activity across durable worker process roles (worker_storage_key + queue_role) as a multi-lane timeline. Hostname and pid remain available on spans for run-location tooltips and restart markers. Hover a span to see what it was doing and, for spans that had to wait, why. The macro (cross-job) lane view drills down into a per-workflow Step/Run waterfall.\n\nIt reads WorkflowActivityEvent/SpawnedProcess/InstanceVersion data and Workflow/Step/Run timestamps; WorkflowActivityEvent#queue_role is captured for RunJob executions, with legacy hostname+pid fallback for older or unattributed rows. Enabling it does not change scheduling, grading, job behavior, or add thread-slot instrumentation.",
      homepage:        "https://github.com/tkadauke/syrus",
      icon_url:        "/plugin-icons/worker_timeline.svg",
      author:          "Thomas Kadauke",
      frontend: {
        routes: {
          "worker_timeline/WorkerTimeline" => "app/frontend/routes/WorkerTimeline.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/worker_timeline.json" ]
      },
      routes: [
        {
          verb: "GET",
          path: "/api/v1/app/admin/worker_timeline/macro",
          controller: "api/v1/app/admin/worker_timeline#macro"
        },
        {
          verb: "GET",
          path: "/api/v1/app/admin/worker_timeline/workflow",
          controller: "api/v1/app/admin/worker_timeline#workflow"
        }
      ],
      provides: {
        sidebar_page: WorkerTimeline::SidebarPages,
        callbacks:    WorkerTimeline::FilterRegistration
      }
    )

    WorkerTimeline::FilterRegistration.register! if enabled?
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "worker_timeline" && manifest.enabled? }
  end
end
