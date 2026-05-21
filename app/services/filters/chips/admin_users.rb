module Filters
  module Chips
    module AdminUsers
      class Email < StringColumn
        filter_name "email"
        label "Email"
        column :email_address
      end

      class BooleanValue < Base
        bucket :boolean
        operators :is, :is_true, :is_false

        class << self
          def column(name = nil)
            @column = name.to_sym if name
            @column or raise NotImplementedError, "#{self.name} must declare `column :name`"
          end
        end

        def apply
          case op
          when :is then scope.where(self.class.column => boolean_value)
          when :is_true then scope.where(self.class.column => true)
          when :is_false then scope.where(self.class.column => false)
          else unsupported_op!
          end
        end

        private

        def boolean_value
          ActiveModel::Type::Boolean.new.cast(value)
        end
      end

      class Admin < BooleanValue
        filter_name "admin"
        label "Admin"
        column :admin
      end

      class TokenPresence < Base
        bucket :boolean
        operators :is, :is_true, :is_false

        def apply
          present = case op
          when :is then ActiveModel::Type::Boolean.new.cast(value)
          when :is_true then true
          when :is_false then false
          else unsupported_op!
          end

          present ? present_scope : missing_scope
        end

        private

        def present_scope
          scope.where.not(self.class.column => nil)
        end

        def missing_scope
          scope.where(self.class.column => nil)
        end
      end

      class HasGithubToken < TokenPresence
        filter_name "has_github_token"
        label "Has GitHub token"

        class << self
          def column = :github_token
        end
      end

      class HasClaudeToken < TokenPresence
        filter_name "has_claude_token"
        label "Has Claude token"

        class << self
          def column = :claude_oauth_token
        end
      end

      class HasCodexToken < TokenPresence
        filter_name "has_codex_token"
        label "Has Codex token"

        private

        def present_scope
          scope.where("codex_api_key IS NOT NULL OR codex_auth_json IS NOT NULL")
        end

        def missing_scope
          scope.where(codex_api_key: nil, codex_auth_json: nil)
        end
      end

      class GhRate < Base
        filter_name "gh_rate"
        label "GitHub rate"
        bucket :enum
        operators :is, :is_not
        values "low", "exhausted"

        def apply
          matched = case value.to_s
          when "low" then low_scope
          when "exhausted" then scope.where(gh_rate_limit_remaining: 0)
          else scope.none
          end

          case op
          when :is then matched
          when :is_not then scope.where.not(id: matched.select(:id))
          else unsupported_op!
          end
        end

        private

        def low_scope
          scope.where(
            "gh_rate_limit_remaining IS NOT NULL AND gh_rate_limit_limit > 0 AND gh_rate_limit_remaining < gh_rate_limit_limit * ?",
            ::Admin::UsersFilter::GH_RATE_LOW_THRESHOLD
          )
        end
      end
    end
  end
end
