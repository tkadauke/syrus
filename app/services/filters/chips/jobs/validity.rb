module Filters
  module Chips
    module Jobs
      class Validity < EnumColumn
        filter_name "validity"
        label "Validity"
        column :validity
        values "valid", "duplicate", "already_implemented"
      end
    end
  end
end
