require "digest"

module ProviderRouting
  class RuleSet
    include AgentProviderCatalogOptions

    StaleRevision = Class.new(StandardError)
    InvalidOperation = Class.new(StandardError)
    PreviewRollback = Class.new(StandardError)

    RULE_ATTRIBUTES = %w[task_key enabled trigger conditions action candidates].freeze

    def initialize(scope_type:, scope_id:, user_id:, repository_id: nil, job_id: nil)
      @scope = {
        scope_type: scope_type.to_s,
        scope_id: scope_id.to_i,
        user_id: user_id.to_i,
        repository_id: repository_id&.to_i,
        job_id: job_id&.to_i
      }.compact
      @user = User.find(user_id)
    end

    attr_reader :scope

    def snapshot
      rules = ordered_rules
      {
        scope: scope,
        rules: rules.map { |rule| serialize_rule(rule) },
        inherited_context: inherited_context,
        registry_options: registry_options,
        active_holds: active_holds(rules),
        revision: revision_for(rules)
      }
    end

    def mutate!(operations:, expected_revision:, preview: false)
      result = nil
      self.class.transaction(requires_new: true) do
        rules = locked_rules
        actual_revision = revision_for(rules)
        raise StaleRevision, "rule set changed (expected #{expected_revision}, current #{actual_revision})" unless ActiveSupport::SecurityUtils.secure_compare(expected_revision.to_s, actual_revision)

        Array(operations).each { |operation| apply_operation!(operation.to_h.deep_stringify_keys) }
        normalize_positions!
        result = snapshot
        raise PreviewRollback if preview
      end
      result
    rescue PreviewRollback
      result
    end

    def self.transaction(**options, &block)
      ProviderRoutingRule.transaction(**options, &block)
    end

    private

    def relation
      ProviderRoutingRule.where(scope_type: scope.fetch(:scope_type), scope_id: scope.fetch(:scope_id))
    end

    def ordered_rules
      relation.order(:position, :id).to_a
    end

    def locked_rules
      relation.lock.order(:position, :id).to_a
    end

    def revision_for(rules)
      payload = rules.map do |rule|
        serialize_rule(rule).slice(:id, :position, :enabled, :task_key, :trigger, :conditions, :action, :candidates)
      end
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def serialize_rule(rule)
      {
        id: rule.id,
        scope_type: rule.scope_type,
        scope_id: rule.scope_id,
        position: rule.position,
        enabled: rule.enabled?,
        task_key: rule.task_key,
        trigger: rule.trigger,
        conditions: rule.conditions,
        action: rule.serialized_action,
        candidates: Array(rule.action_candidates),
        created_at: rule.created_at&.iso8601,
        updated_at: rule.updated_at&.iso8601
      }
    end

    def inherited_context
      inherited_scopes.filter_map do |inherited_scope|
        rules = ProviderRoutingRule.where(inherited_scope).order(:position, :id).to_a
        next if rules.empty?

        {
          scope_type: inherited_scope.fetch(:scope_type),
          scope_id: inherited_scope.fetch(:scope_id),
          rules: rules.map { |rule| serialize_rule(rule) }
        }
      end
    end

    def inherited_scopes
      values = []
      values << { scope_type: "repository", scope_id: scope[:repository_id] } if scope[:scope_type] == "job" && scope[:repository_id]
      values << { scope_type: "user", scope_id: scope[:user_id] } unless scope[:scope_type] == "user"
      values
    end

    def registry_options
      agent_provider_catalog_options(@user).merge(
        step_kinds: Step::Kind.entries.select(&:agentic).map(&:kind),
        chat_roles: AgentRole::CHAT_ROLES,
        workflow_trigger_kinds: Workflow::TriggerKind.values,
        action_types: ProviderRoutingRule::ACTION_TYPES,
        action_strategies: ProviderRoutingRule::ACTION_STRATEGIES,
        condition_keys: ProviderRoutingRule::CONDITION_KEYS
      )
    end

    def active_holds(rules)
      rule_ids = rules.map(&:id) + inherited_scopes.flat_map do |inherited_scope|
        ProviderRoutingRule.where(inherited_scope).pluck(:id)
      end
      ProviderRoutingHold.active.where(provider_routing_rule_id: rule_ids).order(:created_at, :id).map do |hold|
        {
          id: hold.id,
          workflow_id: hold.workflow_id,
          step_id: hold.step_id,
          provider_routing_rule_id: hold.provider_routing_rule_id,
          reason: hold.reason,
          resumption_mode: hold.resumption_mode,
          condition_evidence: hold.condition_evidence,
          next_reevaluation_at: hold.next_reevaluation_at&.iso8601
        }.compact
      end
    end

    def apply_operation!(operation)
      type = operation.fetch("type", "").to_s
      handler = "apply_#{type}!"
      raise InvalidOperation, "unknown operation type #{type.inspect}" unless respond_to?(handler, true)

      send(handler, operation)
    end

    def apply_create!(operation)
      attrs = rule_attributes(operation.fetch("rule", {}))
      relation.create!(attrs.merge(scope).merge(position: relation.maximum(:position).to_i + 1))
    end

    def apply_update!(operation)
      scoped_rule!(operation).update!(rule_attributes(operation.fetch("rule", {})))
    end

    def apply_set_enabled!(operation)
      scoped_rule!(operation).update!(enabled: ActiveModel::Type::Boolean.new.cast(operation.fetch("enabled")))
    end

    def apply_delete!(operation)
      scoped_rule!(operation).destroy!
    end

    def apply_reorder!(operation)
      rules = ordered_rules
      ids = Array(operation["ids"]).map { |id| Integer(id, exception: false) }
      raise InvalidOperation, "reorder ids must contain every rule exactly once" unless ids.none?(&:nil?) && ids.sort == rules.map(&:id).sort

      rules.each_with_index { |rule, index| rule.update_columns(position: -(index + 1), updated_at: Time.current) }
      ids.each_with_index { |id, index| relation.find(id).update!(position: index + 1) }
    end

    def scoped_rule!(operation)
      relation.find(Integer(operation.fetch("id")))
    rescue KeyError, ArgumentError, ActiveRecord::RecordNotFound
      raise InvalidOperation, "operation references a rule outside this scope"
    end

    def rule_attributes(value)
      value.to_h.deep_stringify_keys.slice(*RULE_ATTRIBUTES)
    end

    def normalize_positions!
      ordered_rules.each_with_index do |rule, index|
        next if rule.position == index + 1

        rule.update_columns(position: index + 1, updated_at: Time.current)
      end
    end
  end
end
