module Filters
  module Chips
    module Jobs
      # The chip surfaces two kinds of values:
      #
      # 1. Composites — "open" maps to Job.open_threads (everything
      #    that isn't closed/merged), "closed" maps to
      #    Job.closed_threads (closed or merged). These collide with
      #    the AASM :open / :closed state names; the composites win.
      #    Labeled distinctly in the picker ("Any open", "Closed or
      #    merged") to make the override obvious.
      # 2. Individual AASM states (triaging, queued, running,
      #    implemented, failed, approved, landing, blocked_by_epic)
      #    — passed through as literal `state` column matches via the
      #    `else` branch in scope_for. The AASM :open and :closed
      #    states aren't in the picker because they'd duplicate the
      #    composite value names; operators who need them can still
      #    pass them via URL params and the literal-match path will
      #    handle them.
      #
      # Ordering follows the lifecycle so the picker reads top-to-
      # bottom as "this is what a Job goes through."
      class State < Base
        filter_name "state"
        label "State"
        bucket :enum
        operators :is, :is_not, :is_one_of, :is_none_of
        values(
          { "value" => "open",   "label" => "Any open" },
          { "value" => "closed", "label" => "Closed or merged" },
          "backlog",
          "triaging",
          "blocked_by_epic",
          "queued",
          "running",
          "implemented",
          "failed",
          "approved",
          "landing"
        )

        def apply
          case op
          when :is        then match([ value ])
          when :is_one_of then match(Array(value))
          when :is_not    then not_match([ value ])
          when :is_none_of then not_match(Array(value))
          else unsupported_op!
          end
        end

        private

        def match(values)
          scope.where(id: union_ids(values))
        end

        def not_match(values)
          scope.where.not(id: union_ids(values))
        end

        def union_ids(values)
          # OR-union the matching id sets for every requested value. Pluck
          # is acceptable here for the same reason the Compiler does it
          # for OR-groups: the typical state filter touches a small number
          # of rows relative to the user-scoped base.
          values.flat_map { |v| scope_for(v).pluck(:id) }.uniq
        end

        def scope_for(value)
          case value.to_s
          when "open"   then Job.open_threads
          when "closed" then Job.closed_threads
          else Job.where(state: value)
          end
        end
      end
    end
  end
end
