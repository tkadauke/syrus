module CredentialStore
  class CredentialDiscovery
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 50
    SAFE_COLUMNS = %i[
      id name description credential_type scope_type scope_id safe_metadata
      target_constraints allowed_surfaces allowed_tools expires_at last_rotated_at
    ].freeze

    class InvalidFilter < StandardError; end

    def self.call(context:, credential_type: nil, scope: nil, query: nil, limit: DEFAULT_LIMIT)
      new(context: context, credential_type: credential_type, scope: scope, query: query, limit: limit).call
    end

    def initialize(context:, credential_type:, scope:, query:, limit:)
      @context = context
      @credential_type = credential_type.to_s.strip.presence
      @scope = scope.to_s.strip.downcase.presence
      @query = query.to_s.strip.presence
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
    end

    def call
      validate_scope!
      credentials = CredentialScope::Base.visible_relation(filtered_scope, context)
        .select(*SAFE_COLUMNS)
        .order(Arel.sql("LOWER(name) ASC"), :id)
      visible = visible_credentials(credentials)
      labels = scope_labels(visible)

      {
        credentials: visible.map { |credential| credential_json(credential, labels) },
        count: visible.size,
        limit: limit,
        guidance: visible.empty? ? "No applicable stored credentials are visible. Open Credential Store to add one or review its scope, surface, and expiration." : nil,
        access_notice: "Discovery returns non-secret metadata only and does not grant credential use. Execution still requires broker authorization, permissions, leases, target checks, and audit logging."
      }.compact
    end

    private

    attr_reader :context, :credential_type, :scope, :query, :limit

    def filtered_scope
      relation = Credential.where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current)
      relation = relation.where(credential_type: credential_type) if credential_type
      relation = relation.where(scope_type: scope) if scope
      if query
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
        relation = relation.where("name LIKE :pattern OR description LIKE :pattern", pattern: pattern)
      end
      relation
    end

    def surface_allowed?(credential)
      Broker.surface_allowed?(credential, surface: context.run? ? "workflow" : context.surface)
    end

    def visible_credentials(relation)
      results = []
      offset = 0

      loop do
        rows = relation.limit(MAX_LIMIT).offset(offset).to_a
        results.concat(rows.select { |credential| surface_allowed?(credential) })
        return results.first(limit) if results.size >= limit || rows.size < MAX_LIMIT

        offset += rows.size
      end
    end

    def validate_scope!
      return if scope.nil? || Credential::ALLOWED_SCOPES.include?(scope)

      raise InvalidFilter, "scope must be one of: #{Credential::ALLOWED_SCOPES.join(', ')}"
    end

    def scope_labels(credentials)
      credentials.group_by(&:scope_type).each_with_object({}) do |(scope_type, records), labels|
        ids = records.map(&:scope_id).uniq
        ManagementScope::Base.for(scope_type).labels_for(ids).each do |scope_id, label|
          labels[[ scope_type, scope_id.presence&.to_i ]] = label
        end
      rescue KeyError
        labels
      end
    end

    def credential_json(credential, labels)
      {
        id: credential.id,
        reference: credential.id.to_s,
        name: credential.name,
        description: credential.description,
        credential_type: credential.credential_type,
        scope: credential.scope_type,
        scope_id: credential.scope_id,
        scope_label: labels[[ credential.scope_type, credential.scope_id.presence&.to_i ]],
        safe_metadata: credential.safe_metadata || {},
        target_constraints: credential.target_constraints || {},
        allowed_surfaces: credential.allowed_surfaces || [],
        allowed_tools: credential.allowed_tools || [],
        effective_typed_consumers: ConsumerRegistry.typed_for(credential.credential_type).map(&:name),
        explicit_wrapper_grants: explicit_wrapper_grants(credential),
        expires_at: credential.expires_at&.iso8601,
        last_rotated_at: credential.last_rotated_at&.iso8601,
        expiration_status: credential.expires_at ? "active_until_expiration" : "does_not_expire",
        rotation_status: credential.last_rotated_at ? "rotated" : "not_recorded"
      }
    end

    def explicit_wrapper_grants(credential)
      compatible = ConsumerRegistry.raw_wrappers_for(credential.credential_type).map(&:name)
      Array(credential.allowed_tools) & compatible
    end
  end
end
