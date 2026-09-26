module Filters
  module Chips
    module AdminUsers
      class GithubApiBlockedReason < StringColumn
        filter_name "github_api_blocked_reason"
        label "GitHub API blocked reason"
        column :gh_api_blocked_reason
      end
    end
  end
end
