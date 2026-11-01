module Admin
  class PermissionParityDiagnostics
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 500

    def initialize(limit: DEFAULT_LIMIT, relation: OperationalLogEvent.all)
      @limit = (limit.presence || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
      @relation = relation
    end

    def as_json
      rows = @relation.where(source: Permissions::ShadowEvaluator::LOG_SOURCE)
        .order(occurred_at: :desc).limit(@limit).to_a
      {
        total: rows.length,
        mismatches: rows.count { |row| row.context["status"] == "mismatch" },
        evaluation_failures: rows.count { |row| row.context["status"].to_s.start_with?("evaluation_failed") },
        safe_local_failures: rows.count { |row| row.context["status"] == "evaluation_failed_safe_local" },
        by_capability: grouped(rows, "capability"),
        by_role: grouped(rows, "role"),
        events: rows.map { |row| serialize(row) }
      }
    end

    private

    def grouped(rows, key)
      rows.group_by { |row| row.context[key].presence || "unknown" }
        .transform_values(&:length).sort_by { |name, count| [ -count, name ] }.to_h
    end

    def serialize(row)
      {
        id: row.id,
        occurred_at: row.occurred_at,
        status: row.context["status"],
        tool_name: row.context["tool_name"],
        capability: row.context["capability"],
        operation: row.context["operation"],
        role: row.context["role"],
        current_policy: row.context["current_policy"],
        shadow_policy: row.context["shadow_policy"],
        safe_local: row.context["safe_local"],
        error: row.context["error"]
      }.compact
    end
  end
end
