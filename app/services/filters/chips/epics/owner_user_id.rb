module Filters
  module Chips
    module Epics
      # Filters epics by owner. Supports two special symbolic values:
      #   "me"        — epics owned by the current user (checks both owner_user_id and owner_id)
      #   "unclaimed" — epics with no owner set
      # The is_set / is_unset operators check for any owner / no owner.
      class OwnerUserId < Base
        filter_name "owner_user_id"
        label "Owner"
        bucket :enum
        operators :is, :is_not, :is_set, :is_unset

        values(
          { "value" => "me", "label" => "Me" },
          { "value" => "unclaimed", "label" => "Unclaimed" }
        )

        def apply
          case op
          when :is
            case value.to_s
            when "me"       then scope.where(owned_by_user_condition)
            when "unclaimed" then scope.where(no_owner_condition)
            else
              id = Integer(value, exception: false)
              id ? scope.where(owner_user_id: id).or(scope.where(owner_id: id)) : scope.none
            end
          when :is_not
            case value.to_s
            when "me"       then scope.where.not(id: scope.where(owned_by_user_condition).select(:id))
            when "unclaimed" then scope.where.not(id: scope.where(no_owner_condition).select(:id))
            else
              id = Integer(value, exception: false)
              id ? scope.where.not(owner_user_id: id).where.not(owner_id: id) : scope
            end
          when :is_set   then scope.where(has_owner_condition)
          when :is_unset then scope.where(no_owner_condition)
          else unsupported_op!
          end
        end

        private

        def owned_by_user_condition
          return Epic.arel_table[:id].eq(nil) unless user

          table = Epic.arel_table
          table[:owner_user_id].eq(user.id).or(table[:owner_id].eq(user.id))
        end

        def no_owner_condition
          table = Epic.arel_table
          table[:owner_user_id].eq(nil).and(table[:owner_id].eq(nil))
        end

        def has_owner_condition
          table = Epic.arel_table
          table[:owner_user_id].not_eq(nil).or(table[:owner_id].not_eq(nil))
        end
      end
    end
  end
end
