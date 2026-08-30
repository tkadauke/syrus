module WorkerTimeline
  class FilterRegistration
    include Syrus::Plugin::Callbacks

    SUBJECT = :worker_timeline
    SURFACE = "worker_timeline"

    CHIPS = {
      "repository_id" => "Filters::Chips::WorkerTimeline::RepositoryId",
      "epic_id"       => "Filters::Chips::WorkerTimeline::EpicId",
      "hostname"      => "Filters::Chips::WorkerTimeline::Hostname",
      "status"        => "Filters::Chips::WorkerTimeline::Status",
      "window"        => "Filters::Chips::WorkerTimeline::Window"
    }.freeze

    def self.on_boot = register!
    def self.on_enable = register!
    def self.on_disable = unregister!
    def self.on_shutdown = unregister!

    def self.register!
      Filters.register_subject(name: SUBJECT, model: Workflow, chips: CHIPS)
      FilterUsage.register_surface(SURFACE)
      FilterUsage.register_subject(SURFACE)
    end

    def self.unregister!
      Filters.unregister_subject(SUBJECT)
      FilterUsage.unregister_surface(SURFACE)
      FilterUsage.unregister_subject(SURFACE)
    end
  end
end
