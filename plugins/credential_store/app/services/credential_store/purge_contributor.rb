module CredentialStore
  class PurgeContributor
    include Syrus::Plugin::PurgeContributor

    def self.purge_report(plugin_name)
      return [] if plugin_name == "credential_store"

      credentials = managed_credentials(plugin_name)
      report(audit_count: CredentialAccessEvent.where(credential_id: credentials.select(:id)).count,
        credential_count: credentials.count)
    end

    def self.purge!(plugin_name)
      return [] if plugin_name == "credential_store"

      audit_count = credential_count = 0
      Credential.transaction do
        credentials = managed_credentials(plugin_name)
        audit_count = CredentialAccessEvent.where(credential_id: credentials.select(:id)).delete_all
        credential_count = credentials.delete_all
      end
      report(audit_count:, credential_count:)
    end

    def self.managed_credentials(plugin_name)
      prefix = "#{plugin_name}."
      Credential.where("credential_type >= ? AND credential_type < ?", prefix, "#{plugin_name}/")
    end
    private_class_method :managed_credentials

    def self.report(audit_count:, credential_count:)
      []
        .tap { |items| items << "#{audit_count} plugin credential audit rows" if audit_count.positive? }
        .tap { |items| items << "#{credential_count} plugin-managed encrypted credentials" if credential_count.positive? }
    end
    private_class_method :report
  end
end
