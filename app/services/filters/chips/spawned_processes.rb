module Filters
  module Chips
    module SpawnedProcesses
      class State < Base
        filter_name "state"
        label "State"
        bucket :enum
        operators :is, :is_not
        values "running", "finished", "failed"

        def apply
          matched = case value.to_s
          when "running" then scope.running
          when "finished" then scope.finished
          when "failed" then scope.where(outcome: "failed")
          else scope.none
          end

          case op
          when :is then matched
          when :is_not then scope.where.not(id: matched.select(:id))
          else unsupported_op!
          end
        end
      end

      class Kind < EnumColumn
        filter_name "kind"
        label "Kind"
        column :kind
        values SpawnedProcess::KINDS
      end

      class Hostname < StringColumn
        filter_name "hostname"
        label "Host"
        column :hostname
      end

      class RunId < FkColumn
        filter_name "run_id"
        label "Run"
        column :run_id
        typeahead true
      end

      class WorkflowId < FkColumn
        filter_name "workflow_id"
        label "Workflow"
        column :workflow_id
        typeahead true
      end

      class Stale < Base
        filter_name "stale"
        label "Stale"
        bucket :boolean
        operators :is, :is_true, :is_false

        def apply
          stale_scope = scope.merge(SpawnedProcess.stale)
          stale = case op
          when :is then ActiveModel::Type::Boolean.new.cast(value)
          when :is_true then true
          when :is_false then false
          else unsupported_op!
          end

          stale ? stale_scope : scope.where.not(id: stale_scope.select(:id))
        end
      end
    end
  end
end
