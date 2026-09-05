module Syrus
  module Plugin
    # Marker interface for a plugin that creates Jobs.
    #
    # `Job` used to record its provenance five overlapping ways -- `kind`,
    # `input_source_id`, `external_ref`, `issue_number`, `scheduled_task_id` --
    # and each new source added another special case, plus a column on `jobs`
    # pointing at a plugin's table. `jobs.origin` names the plugin and
    # `jobs.origin_id` is that plugin's own identifier for the thing that
    # caused the Job. Core never parses `origin_id`.
    #
    #   def self.origin_key = "scheduled_tasks"
    #   def self.label(origin_id:, repository:) = "Nightly dependency sweep"
    #   def self.url(origin_id:, repository:)   = "/scheduled_tasks/#{origin_id}"
    #
    # `url` may return nil -- a deploy Job has no page to link to. `icon` is
    # optional.
    #
    # The point of routing this through the registry rather than a column: when
    # the owning plugin is disabled or uninstalled, core degrades to rendering
    # the raw `origin`/`origin_id` strings. No dangling reference, no crash, no
    # orphaned foreign key -- which is what a `scheduled_task_id` column can
    # never give us.
    module JobOrigin
      def self.included(base) = base.extend(self)

      def origin_key = raise(NotImplementedError, "#{self} must define .origin_key")

      def label(origin_id:, repository: nil) = origin_id.to_s

      def url(origin_id:, repository: nil) = nil

      def icon = nil
    end
  end
end
