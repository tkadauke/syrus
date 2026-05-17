module Filters
  module Chips
    module Epics
      class Attention < Base
        filter_name "attention"
        label "Attention preset"
        bucket :preset
        operators :is

        PRESETS = %w[
          ready_to_start in_progress stalled empty blocked_by_dependency recently_done
        ].freeze

        values(*PRESETS)

        EXPANSIONS = {
          "ready_to_start" => -> { chip_node("state", "is", "ready") },
          "in_progress" => -> { chip_node("state", "is", "in_progress") },
          "empty" => -> { chip_node("has_child_jobs", "is_false", nil) },
          "blocked_by_dependency" => -> { chip_node("has_epic_dependency", "is_true", nil) },
          "recently_done" => -> {
            and_node(
              chip_node("state", "is", "done"),
              chip_node("done_at", "within_last", { "n" => 7, "unit" => "days" })
            )
          }
        }.freeze

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

          case value.to_s
          when "ready_to_start" then scope.where(state: "ready")
          when "in_progress" then scope.where(state: "in_progress")
          when "stalled" then scope.where(state: "in_progress").where.not(id: recently_active_epic_ids)
          when "empty" then scope.where.not(id: Job.where.not(epic_id: nil).select(:epic_id))
          when "blocked_by_dependency" then scope.where(id: blocked_epic_ids)
          when "recently_done" then scope.where(state: "done", done_at: 7.days.ago..)
          else scope
          end
        end

        private

        def recently_active_epic_ids
          Job.joins(:runs).where(runs: { updated_at: 7.days.ago.. }).where.not(epic_id: nil).select(:epic_id)
        end

        def blocked_epic_ids
          EpicDependency.where.not(depends_on_epic_id: Epic.where(state: "done").select(:id)).select(:epic_id)
        end
      end
    end
  end
end
