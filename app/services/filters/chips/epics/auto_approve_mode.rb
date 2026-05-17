module Filters
  module Chips
    module Epics
      class AutoApproveMode < EnumColumn
        filter_name "auto_approve_mode"
        label "Auto approve mode"
        column :auto_approve_mode
        values(*AutoApproveModes::MODES)
      end
    end
  end
end
