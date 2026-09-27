module Filters
  module Chips
    module ChatMessages
      class Mode < ChatSessionEnumColumn
        filter_name "mode"
        label "Mode"
        column :mode

        def self.values
          ChatSession::MODES
        end
      end
    end
  end
end
