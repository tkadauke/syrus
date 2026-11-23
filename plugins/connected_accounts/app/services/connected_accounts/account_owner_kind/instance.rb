module ConnectedAccounts
  module AccountOwnerKind
    class Instance < Base
      def validate_account(account)
        account.errors.add(:owner_user, I18n.t("connected_accounts.errors.instance_owner_forbidden")) if account.owner_user.present?
        account.errors.add(:acting_modes, I18n.t("connected_accounts.errors.instance_service_only")) unless account.acting_modes == [ "as_service" ]
      end

      def validate_credential(account, credential)
        return if credential.scope_type == "instance" && credential.owner_user_id.blank?
        account.errors.add(:credential_store_credential, I18n.t("connected_accounts.errors.instance_scope"))
      end

      def validate_access!(_account, context)
        return if context.permission_authorization["system_service_identity"].present?
        raise AccountClient::Denied, "connected account not found"
      end

      def system_access? = true
      def visible_to?(_account, user) = user&.admin? || false
    end
  end
end
