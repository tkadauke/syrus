module CredentialStore
  class ManagementPayload
    def initialize(user:, credentials:)
      @user = user
      @credentials = credentials
    end

    def as_json(*)
      authorization = ManagementAuthorization.new(user)
      {
        credentials: credentials.map { |credential| credential_json(credential, authorization: authorization) },
        options: {
          credential_types: credential_types,
          scopes: Credential::ALLOWED_SCOPES.map { |scope| { value: scope, label: scope.titleize } },
          safe_metadata_keys: Credential::SAFE_METADATA_KEYS,
          target_constraint_keys: Credential::TARGET_CONSTRAINT_KEYS
        }.merge(authorization.manageable_options)
      }
    end

    def self.credential_json(credential, user:)
      authorization = ManagementAuthorization.new(user)
      new(user: user, credentials: []).credential_json(credential, authorization: authorization)
    end

    def credential_json(credential, authorization:)
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
        can_manage: authorization.can_manage?(credential),
        created_by: user_json(credential.created_by),
        owner_user: user_json(credential.owner_user),
        last_access: access_event_json(credential.access_events.order(created_at: :desc, id: :desc).first),
        created_at: credential.created_at.iso8601,
        updated_at: credential.updated_at.iso8601
      }
    end

    private

    attr_reader :user, :credentials

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
      ManagementScope::Base.for(credential.scope_type).label(credential.scope_id)
    rescue KeyError
      nil
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
  end
end
