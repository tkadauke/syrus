module Filters
  module Chips
    module SpawnedProcesses
      class Hostname < Base
        filter_name "hostname"
        label "Hostname"
        bucket :enum
        operators :is

        def self.values
          SpawnedProcess.where("started_at > ?", 24.hours.ago).distinct.pluck(:hostname).compact.sort
        end

        def self.typeahead
          SpawnedProcess.where("started_at > ?", 24.hours.ago).distinct.count(:hostname) > Filters::FkOptionsResolver::LIMIT
        end

        def apply
          case op
          when :is then scope.where(hostname: value)
          else unsupported_op!
          end
        end
      end
    end
  end
end
