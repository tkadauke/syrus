module CredentialStore
  class ManagementPayload
    def initialize(user:, credentials:)
      @user = user
      @credentials = Array(credentials)
      @scope_labels = preload_scope_labels
      @last_access_events = preload_last_access_events
    end

    def self.credential_json(credential, user:)
      authorization = ManagementAuthorization.new(user)
      new(user: user, credentials: [ credential ]).credential_json(credential, manageable_scope_keys: authorization.manageable_scope_keys)
    end

    def credential_json(credential, manageable_scope_keys:)
      {
        id: credential.id,
        name: credential.name,
        description: credential.description,
        credential_type: credential.credential_type,
        scope_type: credential.scope_type,
        scope_id: credential.scope_id,
        scope_label: scope_label(credential),
        safe_metadata: credential.safe_metadata || {},
        target_constraints: credential.target_constraints || {},
        allowed_surfaces: credential.allowed_surfaces || [],
        allowed_tools: credential.allowed_tools || [],
        expires_at: credential.expires_at&.iso8601,
        last_rotated_at: credential.last_rotated_at&.iso8601,
        revoked_at: credential.revoked_at&.iso8601,
        active: credential.active?,
        can_manage: manageable?(credential, manageable_scope_keys: manageable_scope_keys),
        created_by: user_json(credential.created_by),
        owner_user: user_json(credential.owner_user),
        last_access: access_event_json(last_access_events[credential.id]),
        created_at: credential.created_at.iso8601,
        updated_at: credential.updated_at.iso8601
      }
    end

    def as_json(*)
      authorization = ManagementAuthorization.new(user)
      manageable_scope_keys = authorization.manageable_scope_keys
      {
        credentials: credentials.map { |credential| credential_json(credential, manageable_scope_keys: manageable_scope_keys) },
        options: {
          credential_types: credential_types,
          scopes: Credential::ALLOWED_SCOPES.map { |scope| { value: scope, label: scope.titleize } },
          safe_metadata_keys: Credential::SAFE_METADATA_KEYS,
          target_constraint_keys: Credential::TARGET_CONSTRAINT_KEYS
        }.merge(authorization.manageable_options)
      }
    end

    private

    attr_reader :user, :credentials
    attr_reader :scope_labels, :last_access_events

    def credential_types
      Syrus::PluginRegistry.credential_types.sort_by { |entry| entry.fetch("name") }.map do |entry|
        {
          name: entry.fetch("name"),
          label: entry["label"].presence || entry.fetch("name"),
          description: entry["description"].presence,
          plugin: entry["plugin"]
        }.compact
      end
    end

    def scope_label(credential)
      scope_labels.fetch(authorization_key(credential), nil)
    end

    def manageable?(credential, manageable_scope_keys:)
      return true if manageable_scope_keys == :all

      manageable_scope_keys.include?(authorization_key(credential))
    end

    def user_json(candidate)
      return nil unless candidate

      {
        id: candidate.id,
        display_name: candidate.display_name,
        email_address: candidate.email_address
      }
    end

    def access_event_json(event)
      return nil unless event

      {
        id: event.id,
        surface: event.surface,
        action: event.action,
        result: event.result,
        tool_name: event.tool_name,
        purpose: event.purpose,
        denial_reason: event.denial_reason,
        user: user_json(event.user),
        repository_id: event.repository_id,
        job_id: event.job_id,
        workflow_id: event.workflow_id,
        run_id: event.run_id,
        chat_session_id: event.chat_session_id,
        created_at: event.created_at.iso8601
      }
    end

    def preload_scope_labels
      scope_ids_by_type.each_with_object({}) do |(scope_type, scope_ids), labels|
        ManagementScope::Base.for(scope_type).labels_for(scope_ids).each do |scope_id, label|
          labels[[ scope_type, scope_id.presence&.to_i ]] = label
        end
      rescue KeyError
        labels
      end
    end

    def scope_ids_by_type
      credentials.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |credential, grouped|
        grouped[credential.scope_type] << credential.scope_id
      end
    end

    def preload_last_access_events
      ids = credentials.map(&:id)
      return {} if ids.empty?

      CredentialAccessEvent
        .where(id: CredentialAccessEvent.where(credential_id: ids).group(:credential_id).select("MAX(id)"))
        .includes(:user)
        .index_by(&:credential_id)
    end

    def authorization_key(credential)
      [ credential.scope_type.to_s, credential.scope_id.presence&.to_i ]
    end
  end
end
