module WorkerTimeline
  extend Syrus::PluginApi

  FILTER_CHIPS = {
    "repository_id" => "Filters::Chips::WorkerTimeline::RepositoryId",
    "epic_id"       => "Filters::Chips::WorkerTimeline::EpicId",
    "hostname"      => "Filters::Chips::WorkerTimeline::Hostname",
    "job_type"      => "Filters::Chips::WorkerTimeline::JobType",
    "status"        => "Filters::Chips::WorkerTimeline::Status",
    "window"        => "Filters::Chips::WorkerTimeline::Window"
  }.freeze

  syrus_plugin "worker_timeline" do
    display_name "Worker Timeline"
    description "Multi-lane worker activity timeline: one lane per durable worker process role, with Job/Workflow spans over time."
    long_description "Worker Timeline visualizes overlapping Syrus activity across durable worker process roles (worker_storage_key + queue_role) as a multi-lane timeline. Hostname and pid remain available on spans for run-location tooltips and restart markers. Hover a span to see what it was doing and, for spans that had to wait, why. The macro (cross-job) lane view drills down into a per-workflow Step/Run waterfall.\n\nIt reads WorkflowActivityEvent/SpawnedProcess/InstanceVersion data and Workflow/Step/Run timestamps; WorkflowActivityEvent#queue_role is captured for RunJob executions, with legacy hostname+pid fallback for older or unattributed rows. Enabling it does not change scheduling, grading, job behavior, or add thread-slot instrumentation."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/worker_timeline.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled false
    disableable true
    provides sidebar_page: "WorkerTimeline::SidebarPages"
    route :get, "/api/v1/app/admin/worker_timeline/macro", to: "api/v1/app/admin/worker_timeline#macro"
    route :get, "/api/v1/app/admin/worker_timeline/workflow", to: "api/v1/app/admin/worker_timeline#workflow"
    frontend routes: {
          "worker_timeline/WorkerTimeline" => "app/frontend/routes/WorkerTimeline.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/worker_timeline.json" ]


    suggests_enabling "More than one worker host is running, which is when a per-lane view of overlapping activity starts telling you something a single log cannot." do |signals|
      hosts = signals.worker_hostnames
      hosts if hosts.length > 1
    end

    while_enabled do |scope|
      scope.effect("worker_timeline filter subject") do
        Filters.register_subject(name: :worker_timeline, model: Workflow, chips: FILTER_CHIPS)
      end
    end
  end
end
