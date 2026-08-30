module Filters
  module Chips
    module DesignDocs
      class State < EnumColumn
        filter_name "state"
        label "State"
        column :state
        values(*::DesignDocs::DesignDoc::STATES)
      end
    end
  end
end
