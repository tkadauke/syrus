module Filters
  module Chips
    module Workflows
      class Attention < Base
        filter_name "attention"
        label "Attention preset"
        bucket :preset
        operators :is

        PRESETS = %w[ running stuck just_failed queued ].freeze

        values(*PRESETS)

        def apply
          unsupported_op! unless op == :is

          preset = value.to_s
          return scope unless PRESETS.include?(preset)

          send("apply_#{preset}")
        end

        private

        def apply_running
          scope.where(state: "running")
        end

        def apply_stuck
          scope.where(state: "running", id: stuck_workflow_ids)
        end

        def apply_just_failed
          scope.where(state: "failed")
        end

        def apply_queued
          scope.where(state: "queued")
        end

        def stuck_workflow_ids
          Step.where(id: stale_running_runs.select(:step_id)).select(:workflow_id)
        end

        def stale_running_runs
          Run.where(state: "running")
             .where(
               "(last_heartbeat_at IS NOT NULL AND last_heartbeat_at < :t) OR " \
               "(last_heartbeat_at IS NULL AND started_at < :t)",
               t: Admin::StuckItems::ADMIN_STUCK_THRESHOLD.ago
             )
        end
      end
    end
  end
end
