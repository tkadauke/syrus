module MainBranchHealth
  class Setting < ApplicationRecord
    self.table_name = "main_branch_health_settings"

    def self.current
      first_or_create!
    end
  end
end
