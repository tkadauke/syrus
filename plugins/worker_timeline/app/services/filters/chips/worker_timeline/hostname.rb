module Filters
  module Chips
    module WorkerTimeline
      class Hostname < Base
        filter_name "hostname"
        label "Hostname"
        bucket :fk
        operators :is
        typeahead true

        def apply
          case op
          when :is then scope.where(worker_hostname: value)
          else unsupported_op!
          end
        end
      end
    end
  end
end
