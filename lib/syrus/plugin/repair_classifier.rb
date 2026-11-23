module Syrus
  module Plugin
    module RepairClassifier
      extend ActiveSupport::Concern

      class_methods do
        def classify_repair(_context)
          raise NotImplementedError, "#{name} must implement .classify_repair"
        end
      end
    end
  end
end
