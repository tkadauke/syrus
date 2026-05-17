module Filters
  module Chips
    module Jobs
      # The legacy "state" dropdown is conceptually a two-bucket
      # filter: open vs closed. Internally Job's AASM has many states
      # (triaging, queued, running, open, classified, …) — Job's
      # open_threads scope already groups them ("everything that
      # isn't closed/merged") and closed_threads groups the rest.
      # Map "open" / "closed" to those scopes; pass any other value
      # through as a literal `state` column match for forward-looking
      # operators that need to target a specific AASM state directly.
      class State < Base
        filter_name "state"
        label "State"
        bucket :enum
        operators :is, :is_not, :is_one_of, :is_none_of
        values "open", "closed"

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
