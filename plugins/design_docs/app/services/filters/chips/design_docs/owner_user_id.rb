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
          base = [
            { "value" => "me", "label" => "Me" },
            { "value" => "unclaimed", "label" => "Unclaimed" }
          ]
          users = User.order(Arel.sql("LOWER(email_address) ASC"), :id)
            .map { |record| { "value" => record.id.to_s, "label" => record.email_address } }
          base + users
        end

        def apply
          case op
          when :is
            case value.to_s
            when "me" then user ? scope.where(owner_user_id: user.id) : scope.none
            when "unclaimed" then scope.where(owner_user_id: nil)
            else
              id = Integer(value, exception: false)
              id ? scope.where(owner_user_id: id) : scope.none
            end
          when :is_not
            case value.to_s
            when "me" then user ? scope.where.not(owner_user_id: user.id) : scope
            when "unclaimed" then scope.where.not(owner_user_id: nil)
            else
              id = Integer(value, exception: false)
              id ? scope.where.not(owner_user_id: id) : scope
            end
          when :is_set then scope.where.not(owner_user_id: nil)
          when :is_unset then scope.where(owner_user_id: nil)
          else unsupported_op!
          end
        end
      end
    end
  end
end
