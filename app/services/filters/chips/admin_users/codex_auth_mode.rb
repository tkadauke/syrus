module Filters
  module Chips
    module AdminUsers
      class CodexAuthMode < EnumColumn
        filter_name "codex_auth_mode"
        label "Provider auth mode"
        column :codex_auth_mode
        values "api_key", "chatgpt_login"
      end
    end
  end
end
