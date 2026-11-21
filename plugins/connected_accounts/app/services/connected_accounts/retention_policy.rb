module ConnectedAccounts
  class RetentionPolicy
    include Syrus::Plugin::RetentionPolicy

    def self.retention_definitions
      [
        RetentionPolicyRegistry::Definition.new(
          key: :connected_account,
          model: "ConnectedAccounts::Account",
          table_name: "connected_accounts_accounts",
          age_column: :updated_at,
          scope_name: :retention_candidates,
          setting_key: :connected_account_retention_days,
          default_value: 30,
          unit: :days,
          executor_class: "ConnectedAccounts::RetentionExecutor",
          description: "Revoked or failed connected-account records and their broker access audit history.",
          category: "Plugins",
          archivable: false
        )
      ]
    end
  end
end
