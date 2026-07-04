module Filters
  module Chips
    module Jobs
      # Filters jobs by owner_user_id. Supports two special symbolic values:
      #   "me"        — jobs owned by the current user
      #   "unclaimed" — jobs with no owner set
      # The is_set / is_unset operators check for any owner / no owner.
      # schema_values(user) provides the full enum list including team members
      # so the filter bar can show "Owner is Alice" pickers.
      class OwnerUserId < Base
        filter_name "owner_user_id"
        label "Owner"
        bucket :enum
        operators :is, :is_not, :is_set, :is_unset

        values(
          { "value" => "me", "label" => "Me" },
          { "value" => "unclaimed", "label" => "Unclaimed" }
        )

        # Called by Filters::Schema when building the filter schema for a user.
        # Returns the base symbolic values plus all team members so the filter
        # dropdown supports "Owner is Alice" in addition to "Owner is Me".
        def self.schema_values(user)
          base = [
            { "value" => "me", "label" => "Me" },
            { "value" => "unclaimed", "label" => "Unclaimed" }
          ]
          user_opts = User.order(Arel.sql("LOWER(email_address) ASC"), :id)
                         .map { |u| { "value" => u.id.to_s, "label" => u.email_address } }
          base + user_opts
        end

        def apply
          case op
          when :is
            case value.to_s
            when "me"        then scope.where(owned_by_user_condition)
            when "unclaimed" then scope.where(no_owner_condition)
            else
              id = Integer(value, exception: false)
              id ? scope.where(owner_user_id: id) : scope.none
            end
          when :is_not
            case value.to_s
            when "me"        then scope.where.not(id: scope.where(owned_by_user_condition).select(:id))
            when "unclaimed" then scope.where.not(id: scope.where(no_owner_condition).select(:id))
            else
              id = Integer(value, exception: false)
              id ? scope.where.not(id: scope.where(owner_user_id: id).select(:id)) : scope
            end
          when :is_set   then scope.where.not(owner_user_id: nil)
          when :is_unset then scope.where(owner_user_id: nil)
          else unsupported_op!
          end
        end

        private

        def owned_by_user_condition
          return Job.arel_table[:id].eq(nil) unless user

          Job.arel_table[:owner_user_id].eq(user.id)
        end

        def no_owner_condition
          Job.arel_table[:owner_user_id].eq(nil)
        end
      end
    end
  end
end
