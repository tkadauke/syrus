module Filters
  module Chips
    module Workflows
      class Attention < Base
        filter_name "attention"
        label "Preset"
        bucket :preset
        operators :is

        PRESETS = %w[ running stuck just_failed queued interrupted ].freeze

        values(*PRESETS)

        EXPANSIONS = {
          "running"     => -> { chip_node("state", "is", "running") },
          "stuck"       => -> {
            and_node(
              chip_node("state", "is", "running"),
              chip_node("is_stuck", "is_true", nil)
            )
          },
          "just_failed" => -> {
            and_node(
              chip_node("state", "is", "failed"),
              chip_node("finished_at", "within_last", { "n" => 1, "unit" => "hours" })
            )
          },
          "queued"      => -> { chip_node("state", "is", "queued") },
          "interrupted" => -> { chip_node("state", "is", "cancelled") }
        }.freeze

        def self.expansion_for(preset_value)
          builder = EXPANSIONS[preset_value.to_s]
          builder&.call
        end

        def self.expansions
          EXPANSIONS.transform_values(&:call)
        end

        def self.chip_node(field, op, value)
          { "field" => field, "op" => op, "value" => value }
        end

        def self.and_node(*children)
          { "and" => children }
        end

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
          Filters::Chips::Workflows::IsStuck.new(scope: scope, op: :is_true, value: nil, user: user).apply
        end

        def apply_just_failed
          scope.where(state: "failed", finished_at: 1.hour.ago..)
        end

        def apply_queued
          scope.where(state: "queued")
        end

        def apply_interrupted
          scope.where(state: "cancelled")
               .where(id: latest_worker_died_run_workflow_ids)
        end

        def latest_worker_died_run_workflow_ids
          Run.joins(:step)
             .where(agent_outcome: "worker_died")
             .where(<<~SQL.squish)
               runs.id = (
                 SELECT latest_runs.id FROM runs latest_runs
                 INNER JOIN steps latest_steps ON latest_steps.id = latest_runs.step_id
                 WHERE latest_steps.workflow_id = steps.workflow_id
                 ORDER BY latest_runs.created_at DESC, latest_runs.id DESC
                 LIMIT 1
               )
             SQL
             .select("steps.workflow_id")
        end
      end
    end
  end
end
