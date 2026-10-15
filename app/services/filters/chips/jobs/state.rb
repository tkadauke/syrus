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
      # 2. Individual AASM states (backlog, triaging, queued, running,
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
          return scope.none if values.empty?
          return scope.where(state: values) if values.all? { |value| literal_state?(value) }

          scope.where(id: union_scope(values))
        end

        def not_match(values)
          return scope if values.empty?

          scope.where.not(id: union_scope(values))
        end

        def union_scope(values)
          values.map { |v| scope_for(v) }
                .reduce { |left, right| left.or(right) }
                .except(:select, :order)
                .select(:id)
        end

        def scope_for(value)
          case value.to_s
          when "open"   then scope.open_threads
          when "closed" then scope.closed_threads
          when "backlog" then scope.where(state: "backlog", kind: Filters::Chips::Jobs::JobType.user_kinds)
          else scope.where(state: value)
          end
        end

        def literal_state?(value)
          !value.to_s.in?(%w[open backlog])
        end
      end
    end
  end
end
