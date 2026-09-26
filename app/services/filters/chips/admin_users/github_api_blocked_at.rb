module Filters
  module Chips
    module AdminUsers
      class GithubApiBlockedAt < DateColumn
        filter_name "github_api_blocked_at"
        label "GitHub API blocked at"
        column :gh_api_blocked_at
      end
    end
  end
end
