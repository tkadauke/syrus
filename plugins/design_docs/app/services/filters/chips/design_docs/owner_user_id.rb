module Filters
  module Chips
    module DesignDocs
      class OwnerUserId < Base
        filter_name "owner_user_id"
        label "Owner"
        bucket :enum
        operators :is, :is_not, :is_set, :is_unset

        values(
          { "value" => "me", "label" => "Me" },
          { "value" => "unclaimed", "label" => "Unclaimed" }
        )

        def self.schema_values(user)
          [
            { "value" => "me", "label" => "Me" }
          ] + User.order(Arel.sql("LOWER(email_address) ASC"), :id).map { |u| { "value" => u.id.to_s, "label" => u.email_address } }
        end

        def apply
          case op
          when :is
            owner_scope(value)
          when :is_not
            scope.where.not(id: owner_scope(value).select(:id))
          when :is_set
            scope.where.not(owner_user_id: nil)
          when :is_unset
            scope.where(owner_user_id: nil)
          else
            unsupported_op!
          end
        end

        private

        def owner_scope(raw_value)
          return scope.none if raw_value.to_s == "unclaimed"
          return scope.where(owner_user_id: user.id) if raw_value.to_s == "me" && user

          id = Integer(raw_value, exception: false)
          id ? scope.where(owner_user_id: id) : scope.none
        end
      end
    end
  end
end
