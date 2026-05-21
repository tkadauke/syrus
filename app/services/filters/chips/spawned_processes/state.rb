module Filters
  module Chips
    module SpawnedProcesses
      class State < Base
        filter_name "state"
        label "State"
        bucket :enum
        operators :is, :is_one_of
        values "running", "finished"

        def apply
          states = op == :is_one_of ? Array(value) : [ value.to_s ]
          unsupported_op! unless %i[ is is_one_of ].include?(op)

          relation = nil
          relation = scope.running if states.include?("running")
          relation = relation ? relation.or(scope.finished) : scope.finished if states.include?("finished")
          relation || scope.none
        end
      end
    end
  end
end
