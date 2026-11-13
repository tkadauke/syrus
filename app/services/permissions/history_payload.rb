module Permissions
  class HistoryPayload
    PER_PAGE = 25
    HISTORY_LOADERS = {
      "request" => :request_history,
      "invocation" => :invocation_history,
      "rule" => :rule_history,
      "lease" => :lease_history
    }.freeze

    def initialize(user, params: {})
      @user = user
      @params = params
    end

    def as_json
      lease_total = active_leases.count
      filtered_history_total = history_total
      current_lease_page = validated_page(params[:lease_page], lease_total, "lease")
      current_history_page = validated_page(params[:page], filtered_history_total, "history")

      {
        active_leases: paginated_leases(current_lease_page).map { |lease| serialize_lease(lease) },
        leases_pagination: pagination(current_lease_page, lease_total),
        history: paginated_history(current_history_page),
        history_pagination: pagination(current_history_page, filtered_history_total),
        filter: filter_tree,
        filter_schema: HistoryFilter.schema
      }
    end

    private

    attr_reader :user, :params

    def active_leases
      PermissionLease.where(owner_user: user).not_revoked.not_expired.with_uses_remaining
        .includes(:chat_session, :job, :issued_by_user, :source).order(created_at: :desc)
    end

    def paginated_leases(page)
      active_leases.offset((page - 1) * PER_PAGE).limit(PER_PAGE)
    end

    def paginated_history(page)
      references = history_page_references(page)
      entries = history_entries(references).index_by { |source, entry| [ source, entry.fetch(:id) ] }
      references.filter_map { |reference| entries[[ reference.fetch("history_source"), reference.fetch("history_id") ]]&.last }
    end

    def filter_tree
      @filter_tree ||= Filters::QueryParam.decode(params[:q]) || { "and" => [] }
    end

    def validated_page(value, total, label)
      page = [ value.to_i, 1 ].max
      last_page = [ (total + PER_PAGE - 1) / PER_PAGE, 1 ].max
      raise ArgumentError, "invalid permission #{label} page" if page > last_page

      page
    end

    def pagination(page, total, has_more: page * PER_PAGE < total)
      { page:, per_page: PER_PAGE, total:, total_pages: [ (total + PER_PAGE - 1) / PER_PAGE, page + (has_more ? 1 : 0), 1 ].max, has_more: }
    end

    def history_total
      history_filter.apply(request_scope, source: :request).count +
        history_filter.apply(invocation_scope, source: :invocation).count +
        history_filter.apply(rule_scope, source: :rule).count +
        history_filter.apply(lease_scope, source: :lease).count
    end

    def history_filter = @history_filter ||= HistoryFilter.new(filter_tree)

    def request_scope = ChatPendingAction.where(user:, request_kind: "authorization_request")
    def invocation_scope = AuthorizedInvocation.joins(pending_action_item: :chat_pending_action).where(chat_pending_actions: { user_id: user.id })
    def rule_scope = PermissionRuleAuditEvent.joins(:permission_rule, :actor_user).where(permission_rules: { owner_user_id: user.id })
    def lease_scope = PermissionLease.where(owner_user: user)

    def history_page_references(page)
      unions = [
        history_reference_scope(request_scope, :request, "chat_pending_actions"),
        history_reference_scope(invocation_scope, :invocation, "authorized_invocations"),
        history_reference_scope(rule_scope, :rule, "permission_rule_audit_events"),
        history_reference_scope(lease_scope, :lease, "permission_leases")
      ].join(" UNION ALL ")
      offset = (page - 1) * PER_PAGE
      sql = "SELECT history_source, history_id, occurred_at FROM (#{unions}) permission_history " \
        "ORDER BY occurred_at DESC, history_id DESC, history_source ASC LIMIT #{PER_PAGE} OFFSET #{offset}"
      ActiveRecord::Base.connection.select_all(sql).to_a
    end

    def history_reference_scope(scope, source, table)
      history_filter.apply(scope, source:).select(
        "#{ActiveRecord::Base.connection.quote(source.to_s)} AS history_source",
        "#{table}.id AS history_id", "#{table}.created_at AS occurred_at"
      ).to_sql
    end

    def history_entries(references)
      references.group_by { |reference| reference.fetch("history_source") }.flat_map do |source, source_references|
        ids = source_references.pluck("history_id")
        send(HISTORY_LOADERS.fetch(source), ids).map { |entry| [ source, entry ] }
      end
    end

    def request_history(ids)
      request_scope.where(id: ids)
        .preload(:origin, occurrences: :origin, authorization_items: [ :decision_principal, :resulting_authority ])
        .map do |request|
        {
          type: "request", id: request.id, occurred_at: request.created_at, state: request.state,
          purpose: request.purpose, requested_by: request.requested_by,
          non_actionable_reason: request.non_actionable_reason,
          dismissed: request.dismissed?, escalated: request.occurrences.any?,
          origins: serialize_origins(request),
          items: request.authorization_items.map { |item| serialize_item(item) }
        }
      end
    end

    def invocation_history(ids)
      invocation_scope.where(authorized_invocations: { id: ids })
        .preload(:authority, :claimed_by, :result, pending_action_item: :chat_pending_action)
        .map do |invocation|
        {
          type: "invocation", id: invocation.id, occurred_at: invocation.created_at,
          state: invocation.state, tool_name: invocation.tool_name,
          authority: reference(invocation.authority), claimant: reference(invocation.claimed_by),
          claimed_at: invocation.claimed_at, executed_at: invocation.executed_at,
          result_status: invocation.result_status, invalidated_at: invocation.invalidated_at,
          invalidation_reason: invocation.invalidation_reason,
          evidence: ToolPayloadRedactor.redact(invocation.audit_payload)
        }
      end
    end

    def rule_history(ids)
      rule_scope.where(permission_rule_audit_events: { id: ids })
        .includes(:actor_user, :permission_rule).map do |event|
        {
          type: "policy_change", id: event.id, occurred_at: event.created_at,
          state: event.event_type, actor: reference(event.actor_user),
          capability: event.permission_rule.capability, operation: event.permission_rule.operation,
          changed_fields: event.changed_fields,
          evidence: ToolPayloadRedactor.redact(event.snapshot.slice("policy", "resource_scope", "rationale", "revoked_at"))
        }
      end
    end

    def lease_history(ids)
      lease_scope.where(id: ids).includes(:chat_session, :job, :issued_by_user, :revoked_by_user, :source)
        .map do |lease|
        serialize_lease(lease).merge(type: "lease", occurred_at: lease.created_at,
          state: lease.revoked_at? ? "revoked" : lease_state(lease))
      end
    end

    def serialize_lease(lease)
      {
        id: lease.id, capability: lease.capability, operation: lease.operation,
        subject: lease.subject_selector_type, duration: lease.duration_kind,
        resource_type: lease.resource_type, resource_scope: ToolPayloadRedactor.redact(lease.resource_scope),
        used_count: lease.used_count, max_uses: lease.max_uses, expires_at: lease.expires_at,
        revoked_at: lease.revoked_at, issued_at: lease.created_at,
        issued_by: reference(lease.issued_by_user), revoked_by: reference(lease.revoked_by_user),
        origin: reference(lease.source || lease.chat_session || lease.job)
      }
    end

    def serialize_origins(request)
      ([ reference(request.origin) ] + request.occurrences.map do |occurrence|
        reference(occurrence.origin).merge(escalated_at: occurrence.created_at)
      end).compact
    end

    def serialize_item(item)
      {
        id: item.id, kind: item.kind, state: item.state, capability: item.capability,
        operation: item.operation, risk: item.risk, effects: item.effects,
        selected_duration: item.selected_duration, requested_durations: item.requested_durations,
        purpose: item.purpose, decided_at: item.decided_at, decision_reason: item.decision_reason,
        decision_principal: reference(item.decision_principal), authority: reference(item.resulting_authority),
        non_actionable_reason: item.non_actionable_reason,
        evidence: ToolPayloadRedactor.redact(item.normalized_arguments)
      }
    end

    def reference(record)
      return nil unless record

      { type: record.class.base_class.name, id: record.id, label: record_label(record) }
    end

    def record_label(record)
      return record.name if record.respond_to?(:name) && record.name.present?
      return record.title if record.respond_to?(:title) && record.title.present?
      return record.email_address if record.respond_to?(:email_address) && record.email_address.present?

      "#{record.class.base_class.model_name.human} ##{record.id}"
    end

    def lease_state(lease)
      return "expired" if lease.expires_at && lease.expires_at <= Time.current
      return "exhausted" if lease.max_uses && lease.used_count >= lease.max_uses

      "active"
    end
  end
end
