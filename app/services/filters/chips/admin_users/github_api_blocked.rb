module Filters
  module Chips
    module AdminUsers
      class GithubApiBlocked < Base
        filter_name "github_api_blocked"
        label "GitHub API blocked"
        bucket :enum
        operators :is
        values({ value: "true", label: "Blocked" }, { value: "false", label: "Not blocked" })

        def apply
          ActiveModel::Type::Boolean.new.cast(value) ? scope.where.not(gh_api_blocked_at: nil) : scope.where(gh_api_blocked_at: nil)
        end
      end
    end
  end
end
