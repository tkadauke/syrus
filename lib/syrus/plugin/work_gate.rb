module Syrus
  module Plugin
    module WorkGate
      extend ActiveSupport::Concern

      class_methods do
        def work_gate(_context)
          raise NotImplementedError, "#{name} must implement .work_gate"
        end
      end
    end
  end
end
