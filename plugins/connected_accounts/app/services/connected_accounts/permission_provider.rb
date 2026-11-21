module ConnectedAccounts
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ACTING_MODES = %w[as_self as_service as_owner].freeze

    class << self
      def lookup_account(identifier, context:)
        user = context[:user] || context[:mcp_context]&.user
        Account.find_by(id: identifier, owner_user_id: user&.id)
      end

      def normalize_scope(scope, context:)
        source = scope.to_h.stringify_keys
        {
          "account_id" => Integer(source["account_id"], exception: false),
          "acting_mode" => source["acting_mode"].to_s,
          "sub_resources" => source["sub_resources"]
        }.compact
      end

      def validate_scope(scope, context:)
        errors = []
        errors << "account_id must be an integer" unless scope["account_id"].is_a?(Integer)
        errors << "acting_mode is not supported" unless ACTING_MODES.include?(scope["acting_mode"])
        if scope.key?("sub_resources") && !scope["sub_resources"].is_a?(Hash)
          errors << "sub_resources must be an object"
        end
        account = lookup_account(scope["account_id"], context:)
        errors << "connected account not found" unless account
        if account && !account.acting_mode_enabled?(scope["acting_mode"])
          errors << "acting mode is not available for this account"
        end
        errors
      end

      def scope_label(scope, context:)
        account = lookup_account(scope.fetch("account_id"), context:)
        return "Connected account unavailable" unless account

        "#{account.display_label} (#{scope.fetch('acting_mode').tr('_', ' ')})"
      end

      def compare_scopes(left, right, context:)
        return :disjoint unless left["account_id"] == right["account_id"] && left["acting_mode"] == right["acting_mode"]
        return :equal if left == right
        return :broader if left["sub_resources"].blank?
        return :narrower if right["sub_resources"].blank?

        :disjoint
      end

      def authoring_options(context:)
        user = context[:user]
        accounts = Account.where(owner_user_id: user&.id).order(:provider, :display_label, :id)
        {
          fields: [
            { name: "account_id", label: "Connected account", type: "select",
              choices: accounts.map { |account| { value: account.id.to_s, label: account.display_label } } },
            { name: "acting_mode", label: "Acting mode", type: "select",
              choices: ACTING_MODES.map { |mode| { value: mode, label: mode.tr("_", " ") } } }
          ]
        }
      end
    end

    register_resource_scope(
      :connected_account,
      options: {
        fields: [
          { name: "account_id", label: "Connected account ID", type: "integer" },
          { name: "acting_mode", label: "Acting mode", type: "select",
            choices: ACTING_MODES.map { |mode| { value: mode, label: mode.tr("_", " ") } } }
        ]
      },
      lookup: method(:lookup_account), normalize: method(:normalize_scope), validate: method(:validate_scope),
      label: method(:scope_label), compare: method(:compare_scopes), authoring: method(:authoring_options)
    )
  end
end
