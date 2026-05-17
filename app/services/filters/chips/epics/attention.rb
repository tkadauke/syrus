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
          "ready_to_start"        => -> { chip_node("state", "is", "ready") },
          "in_progress"           => -> { chip_node("state", "is", "in_progress") },
          "empty"                 => -> { chip_node("has_child_jobs", "is_false", nil) },
          "blocked_by_dependency" => -> { chip_node("has_epic_dependency", "is_true", nil) },
          "recently_done"         => -> {
            and_node(
              chip_node("state", "is", "done"),
              chip_node("done_at", "within_last", { "n" => 7, "unit" => "days" })
            )
          }
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

        def apply_ready_to_start
          scope.where(state: "ready")
        end

        def apply_in_progress
          scope.where(state: "in_progress")
        end

        def apply_stalled
          scope.where(state: "in_progress")
               .where.not(id: child_run_activity_since(7.days.ago))
        end

        def apply_empty
          scope.where.not(id: Job.where.not(epic_id: nil).select(:epic_id))
        end

        def apply_blocked_by_dependency
          scope.where(id: unresolved_epic_dependency_ids)
        end

        def apply_recently_done
          scope.where(state: "done", done_at: 7.days.ago..)
        end

        def child_run_activity_since(cutoff)
          Epic.joins(jobs: :runs)
              .where("runs.updated_at >= ?", cutoff)
              .select(:id)
        end

        def unresolved_epic_dependency_ids
          EpicDependency.joins(<<~SQL.squish)
            INNER JOIN epics dependency_epics
              ON dependency_epics.id = epic_dependencies.depends_on_epic_id
          SQL
                        .where.not(dependency_epics: { state: "done" })
                        .select(:epic_id)
        end
      end
    end
  end
end
