module Syrus
  module Plugin
    # Interface for features whose published artifacts retain a PreviewPanel
    # after its transient chat tab closes.
    module PreviewPanelRetention
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def retains?(_panel)
          raise NotImplementedError, "#{self}.retains? is required"
        end
      end
    end
  end
end
