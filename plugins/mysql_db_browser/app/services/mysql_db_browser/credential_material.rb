module MysqlDbBrowser
  class CredentialMaterial
    CREDENTIAL_TYPE = "mysql_db_browser.connection".freeze
    CREDENTIAL_ENV_KEY = "MYSQL_DB_BROWSER_PASSWORD".freeze
    LEGACY_CREDENTIAL_TYPE = "legacy_mysql_connection_credentials".freeze

    class CredentialStoreUnavailable < StandardError; end

    class << self
      def store!(connection, password, user:)
        value = password.to_s
        raise ArgumentError, "password is blank" if value.blank?
        raise CredentialStoreUnavailable, "credential_store plugin must be enabled to store MySQL connection passwords" unless credential_store_enabled?

        credential = credential_for(connection) || CredentialStore::Credential.new(created_by: user, owner_user: user)
        credential.assign_attributes(metadata_attributes_for(connection, user: user, credential: credential).merge(
          payload: value,
          last_rotated_at: Time.current,
          revoked_at: nil
        ))
        credential.save!

        connection.update!(credential_store_credential_id: credential.id, credentials: {})
        credential
      end

      def sync_metadata!(connection, user:)
        return nil if connection.credential_store_credential_id.blank?
        raise CredentialStoreUnavailable, "credential_store plugin must be enabled to update MySQL connection credential metadata" unless credential_store_enabled?

        credential = credential_for(connection)
        return nil unless credential

        credential.update!(metadata_attributes_for(connection, user: user, credential: credential))
        credential
      end

      def with_password(connection, context:, purpose:, tool_name: nil)
        if connection.credential_store_credential_id.present?
          raise CredentialStoreUnavailable, "credential_store plugin must be enabled to read MySQL connection passwords" unless credential_store_enabled?

          CredentialStore::Broker.with_credential_env(
            context: context,
            credential: connection.credential_store_credential_id,
            type: CREDENTIAL_TYPE,
            env_key: CREDENTIAL_ENV_KEY,
            purpose: purpose,
            tool_name: tool_name,
            target: { host: connection.host }
          ) do |env, metadata|
            yield env.fetch(CREDENTIAL_ENV_KEY), metadata
          end
        else
          yield connection.password, { credential_id: nil, credential_type: LEGACY_CREDENTIAL_TYPE }
        end
      end

      def credential_for(connection)
        return nil if connection.credential_store_credential_id.blank?

        CredentialStore::Credential.find_by(id: connection.credential_store_credential_id)
      end

      private

      def metadata_attributes_for(connection, user:, credential:)
        {
          name: "mysql-db-browser-connection-#{connection.id}",
          description: "MySQL DB Browser connection: #{connection.label}",
          credential_type: CREDENTIAL_TYPE,
          scope_type: "instance",
          scope_id: nil,
          created_by: credential.created_by || user,
          owner_user: credential.owner_user || user,
          safe_metadata: {
            "host" => connection.host,
            "port" => connection.port,
            "username" => connection.username
          },
          target_constraints: {
            "allowed_hosts" => [ connection.host ]
          },
          allowed_surfaces: %w[admin workflow chat],
          allowed_tools: []
        }
      end

      def credential_store_enabled?
        defined?(CredentialStore) && CredentialStore.enabled?
      end
    end
  end
end
