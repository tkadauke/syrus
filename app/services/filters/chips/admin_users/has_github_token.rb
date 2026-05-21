module Filters
  module Chips
    module AdminUsers
      class HasGithubToken < Base
        filter_name "has_github_token"
        label "GitHub token"
        bucket :enum
        operators :is
        values({ value: "true", label: "Set" }, { value: "false", label: "Missing" })

        def apply
          ActiveModel::Type::Boolean.new.cast(value) ? scope.where.not(github_token: nil) : scope.where(github_token: nil)
        end
      end
    end
  end
end
