module ConnectedAccounts
  module AccountOwnerKind
    class User < Base
      def validate_account(account)
        account.errors.add(:owner_user, I18n.t("connected_accounts.errors.user_owner_required")) if account.owner_user.blank?
      end

      def validate_credential(account, credential)
        return if credential.owner_user_id == account.owner_user_id
        account.errors.add(:credential_store_credential, I18n.t("connected_accounts.errors.same_owner"))
      end

      def validate_access!(account, context)
        return if context.user && account.owner_user_id == context.user.id
        raise AccountClient::Denied, "connected account not found"
      end

      def visible_to?(account, user) = account.owner_user_id == user&.id
    end
  end
end
