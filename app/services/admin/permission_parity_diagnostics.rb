module Admin
  class PermissionParityDiagnostics
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 500

    def initialize(limit: DEFAULT_LIMIT, relation: OperationalLogEvent.all)
      @limit = (limit.presence || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
      @relation = relation
    end

    def as_json
      rows = @relation.where(source: Permissions::DecisionAudit::LOG_SOURCE)
        .order(occurred_at: :desc).limit(@limit).to_a
      {
        total: rows.length,
        policies: grouped(rows, "effective_policy"),
        by_capability: grouped(rows, "capability"),
        by_role: grouped(rows, "role"),
        by_actor: grouped(rows, "actor_type", "actor_id"),
        by_invocation: grouped(rows, "invocation_fingerprint"),
        events: rows.map { |row| serialize(row) }
      }
    end

    private

    def grouped(rows, *keys)
      rows.group_by { |row| keys.map { |key| row.context[key].presence }.compact.join(":").presence || "unknown" }
        .transform_values(&:length).sort_by { |name, count| [ -count, name ] }.to_h
    end

    def serialize(row)
      {
        id: row.id,
        occurred_at: row.occurred_at,
        capability: row.context["capability"],
        operation: row.context["operation"],
        role: row.context["role"],
        policy: row.context["policy"],
        effective_policy: row.context["effective_policy"],
        actor_type: row.context["actor_type"],
        actor_id: row.context["actor_id"],
        invocation_fingerprint: row.context["invocation_fingerprint"],
        decisive_layer: row.context["decisive_layer"],
        decisive_rule_id: row.context["decisive_rule_id"]
      }.compact
    end
  end
end
