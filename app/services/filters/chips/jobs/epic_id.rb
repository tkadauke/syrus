module Filters
  module Chips
    module Jobs
      class EpicId < FkColumn
        filter_name "epic_id"
        label "Epic"
        column :epic_id
      end
    end
  end
end
