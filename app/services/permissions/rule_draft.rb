require "digest"

module Permissions
  # Canonical, descriptor-driven permission rule draft shared by every
  # permission-authoring surface (pending-action cards, the Permissions Hub and
  # confirmed permission-management tool calls).
  #
  # A draft is validated through the same Catalog descriptor, resource scope
  # schema, AuthorityGrant and PolicyEvaluator that run at execution time, so a
  # surface cannot express semantics the runtime would not enforce. Previews
  # carry a digest over the normalized draft, the descriptor contract and the
  # owner's active rules; applying with a stale digest is refused.
  class RuleDraft
    DURATIONS = %w[ chat_session job permanent ].freeze
    POLICIES = CapabilityDescriptor::POLICIES.map(&:to_s).freeze
    ATTRIBUTES = %w[
      policy duration subject_selector_type subject_selector_id subject_type subject_repository_id
      role capability operation resource_scope constraints chat_session_id job_id rationale
    ].freeze
    # Core never constants-depends on plugins: an exact-agent subject class opts
    # in by responding true to .permission_agent_subject? and exposing owner_user_id.
    # The unscoped dynamic selector cannot name an exact subject.
    EXCLUDED_SELECTORS = %w[ eligible_roles ].freeze

    class Stale < StandardError; end

    class Invalid < ArgumentError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.pluck(:message).join("; "))
      end
    end

    Preview = Data.define(:valid, :errors, :warnings, :draft, :summary, :ceiling, :examples, :digest) do
      def valid? = valid

      def to_h
        { valid:, errors:, warnings:, draft:, summary:, ceiling:, examples:, digest: }
      end
    end

    Resolved = Data.define(:descriptor, :attributes, :scope, :repository, :chat_session, :job, :role, :expires_at, :decision)

    def self.from_request_item(user:, request:, item:, duration:, policy: "allow")
      raise ActiveRecord::RecordNotFound, "authorization request belongs to another user" unless request.user_id == user.id
      raise ArgumentError, "authorization item belongs to another request" unless item.chat_pending_action_id == request.id

      lifecycle = { "chat_session_id" => request.chat_session_id&.to_s,
                    "job_id" => (request.origin_id.to_s if request.origin_type == "Job") }.compact
      new(user:, attributes: {
        "policy" => policy, "duration" => duration.to_s,
        "role" => request.runtime_role, "capability" => "#{item.capability}@v#{item.capability_version}",
        "operation" => ("#{item.operation}@v#{item.operation_version}" if item.operation),
        "resource_scope" => item.resource_scope, "constraints" => request_constraints(item)
      }.merge(request_subject(request)).merge(lifecycle), request_scope: item.resource_scope)
    end

    # Builds the same draft a confirmed permission-management tool call will
    # execute, so its readable preview matches what the Hub and cards apply.
    MANAGEMENT_POLICIES = { "grant_permission" => "allow", "deny_permission" => "deny" }.freeze

    def self.from_management_payload(user:, action:, payload:, chat_session: nil)
      payload = payload.to_h.stringify_keys
      case action.to_s
      when "create_permission_lease"
        return unless payload["duration"].present?

        new(user:, attributes: payload.merge("policy" => "allow", "chat_session_id" => payload["chat_session_id"] || chat_session&.id))
      else
        policy = MANAGEMENT_POLICIES[action.to_s]
        policy && new(user:, attributes: payload.merge("policy" => policy, "duration" => "permanent"))
      end
    end

    # Maps the request's runtime context onto the canonical subject selector:
    # an exact agent only for an allowlisted coworker subject, otherwise the
    # chat type or the (repository-scoped) workflow role the request ran as.
    def self.request_subject(request)
      if agent_subject_class(request.subject_type)
        return { "subject_selector_type" => "agent", "subject_selector_id" => request.subject_id.to_s,
                 "subject_type" => request.subject_type, "subject_repository_id" => request.repository_id }
      end

      role = request.runtime_role.to_s
      chat_type = PermissionRule::SUBJECT_SELECTORS.find { |_type, definition| definition[:role] == role }&.first
      return { "subject_selector_type" => chat_type } if chat_type
      return {} unless AgentRole::WORKFLOW_ROLES.include?(role)

      if request.repository_id
        { "subject_selector_type" => "repository_role", "subject_selector_id" => role,
          "subject_repository_id" => request.repository_id }
      else
        { "subject_selector_type" => "workflow_role", "subject_selector_id" => role }
      end
    end

    def self.agent_subject_class(name)
      klass = name.to_s.safe_constantize
      klass if klass.is_a?(Class) && klass < ActiveRecord::Base && klass.respond_to?(:permission_agent_subject?) && klass.permission_agent_subject?
    end

    # Only descriptor-declared, correctly typed, non-secret arguments become
    # constraints; everything else is omitted so the draft never over-claims.
    def self.request_constraints(item)
      descriptor = Catalog.find!(capability: "#{item.capability}@v#{item.capability_version}",
        operation: ("#{item.operation}@v#{item.operation_version}" if item.operation))
      item.normalized_arguments.to_h.stringify_keys.select do |key, value|
        type = descriptor.constraint_fields[key]
        type && !key.match?(ToolPayloadRedactor::SENSITIVE_KEY) && constraint_value_valid?(type, value)
      end.sort.to_h
    rescue Catalog::UnknownCapability
      {}
    end

    def self.constraint_value_valid?(type, value)
      case type
      when :string
        value.is_a?(String) && value.present? && !value.match?(/\A\[redacted\]\z/i) && ToolPayloadRedactor.redact(value) == value
      when :integer then value.is_a?(Integer)
      when :boolean then [ true, false ].include?(value)
      else false
      end
    end

    attr_reader :user

    def initialize(user:, attributes:, request_scope: nil)
      @user = user
      @attributes = normalize_attributes(attributes)
      @request_scope = request_scope
    end

    def preview
      errors = []
      resolved = resolve(errors)
      return invalid_preview(errors) if resolved.nil? || errors.any?

      Preview.new(valid: true, errors: [], warnings: warnings_for(resolved), draft: public_draft(resolved),
        summary: summary_for(resolved), ceiling: ceiling_for(resolved), examples: examples_for(resolved),
        digest: digest_for(resolved))
    end

    def apply!(digest:, actor:)
      current = preview
      raise Invalid, current.errors unless current.valid?
      unless digest.present? && ActiveSupport::SecurityUtils.secure_compare(digest.to_s, current.digest)
        raise Stale, I18n.t("api.permission_rule_drafts.stale_preview")
      end

      PermissionRule.transaction { persist!(actor, @resolved) }
    end

    private

    attr_reader :attributes

    def normalize_attributes(raw)
      raw = raw.to_h.stringify_keys.slice(*ATTRIBUTES)
      raw["policy"] = raw["policy"].presence&.to_s || "allow"
      raw["duration"] = raw["duration"].to_s
      %w[ subject_selector_id subject_repository_id chat_session_id job_id ].each { |key| raw[key] = raw[key].presence&.to_s }
      raw["resource_scope"] = hash_value(raw["resource_scope"])
      raw["constraints"] = hash_value(raw["constraints"])
      raw
    end

    def hash_value(value)
      return {} if value.nil?
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      value.is_a?(Hash) ? value.deep_stringify_keys : value
    end

    def resolve(errors)
      descriptor = find_descriptor(errors)
      return unless descriptor

      validate_policy_and_duration(descriptor, errors)
      role = validate_subject(descriptor, errors)
      repository = resolve_repository(errors)
      constraints = validate_constraints(descriptor, errors)
      scope = normalize_scope(descriptor, errors)
      chat_session, job = resolve_lifecycle(errors)
      return if errors.any?

      decision, expires_at = evaluate(descriptor, role:, repository:, scope:, constraints:, chat_session:, job:, errors:)
      return if errors.any?

      @resolved = Resolved.new(descriptor:, attributes: attributes.merge("constraints" => constraints), scope:,
        repository:, chat_session:, job:, role:, expires_at:, decision:)
    end

    def find_descriptor(errors)
      if attributes["operation"].blank?
        errors << error(:operation_required)
        return
      end
      descriptor = Catalog.find!(capability: attributes["capability"], operation: attributes["operation"])
      return descriptor if descriptor.capability == attributes["capability"].to_s

      errors << error(:unknown_capability)
      nil
    rescue Catalog::UnknownCapability
      errors << error(:unknown_capability)
      nil
    end

    def validate_policy_and_duration(descriptor, errors)
      policy = attributes["policy"]
      duration = attributes["duration"]
      errors << error(:unknown_policy) unless POLICIES.include?(policy)
      unless DURATIONS.include?(duration)
        errors << error(:unsupported_duration)
        return
      end
      # Ask/deny rules are standing rules; only allow authority is time-bounded.
      errors << error(:restrictive_rules_are_permanent) if policy != "allow" && duration != "permanent"
      return unless policy == "allow"

      errors << error(:duration_not_offered) unless descriptor.authority_durations.map(&:to_s).include?(duration)
      if AuthorityGrant::Base::AUTONOMY_RANK.fetch(duration.to_sym) > AuthorityGrant::Base::AUTONOMY_RANK.fetch(descriptor.maximum_autonomy)
        errors << error(duration == "permanent" ? :permanent_forbidden : :exceeds_maximum_autonomy)
      end
    end

    # Returns the role the draft is evaluated as.
    def validate_subject(descriptor, errors)
      type = attributes["subject_selector_type"].to_s
      definition = PermissionRule::SUBJECT_SELECTORS[type]
      if definition.nil? || EXCLUDED_SELECTORS.include?(type)
        errors << error(:unsupported_subject)
        return
      end
      id = attributes["subject_selector_id"]
      errors << error(:subject_id_required) if definition[:id] && id.blank?
      errors << error(:subject_id_forbidden) if !definition[:id] && id.present?
      errors << error(:subject_repository_required) if definition[:repository] && attributes["subject_repository_id"].blank?
      validate_agent_subject(errors) if type == "agent" && id.present?

      role = definition[:role] || (id if definition[:role_from_id]) || attributes["role"]
      unless descriptor.requestable_roles.include?(role.to_s)
        errors << error(:role_not_eligible)
        return
      end
      role.to_s
    end

    def validate_agent_subject(errors)
      klass = self.class.agent_subject_class(attributes["subject_type"])
      subject = klass&.find_by(id: attributes["subject_selector_id"])
      errors << error(:unknown_subject) unless subject && subject.owner_user_id == user.id
    end

    def resolve_repository(errors)
      return if attributes["subject_repository_id"].blank?

      scope = user.admin? ? Repository.active : Repository.accessible_to(user).active
      scope.find_by(id: attributes["subject_repository_id"]).tap { |repo| errors << error(:unknown_repository) unless repo }
    end

    def validate_constraints(descriptor, errors)
      constraints = attributes["constraints"]
      unless constraints.is_a?(Hash)
        errors << error(:invalid_constraints)
        return {}
      end
      return {} if constraints.empty?

      # Rules do not enforce argument constraints at evaluation time, so a
      # permanent constrained rule would silently apply to every argument.
      errors << error(:constraints_not_enforceable) if attributes["duration"] == "permanent" || attributes["policy"] != "allow"
      constraints.each do |key, value|
        type = descriptor.constraint_fields[key.to_s]
        if type.nil? || key.to_s.match?(ToolPayloadRedactor::SENSITIVE_KEY)
          errors << error(:constraint_not_supported, field: key)
        elsif !constraint_value_valid?(type, value)
          errors << error(:constraint_invalid_value, field: key)
        end
      end
      constraints.sort.to_h
    end

    def constraint_value_valid?(type, value) = self.class.constraint_value_valid?(type, value)

    def normalize_scope(descriptor, errors)
      return {} unless attributes["resource_scope"].is_a?(Hash)

      normalized = descriptor.resource_scope.normalize(attributes["resource_scope"], context: { user: })
      if normalized.fail_closed?
        errors << error(:invalid_resource_scope)
        return
      end
      normalized.value
    end

    def resolve_lifecycle(errors)
      chat_session = job = nil
      case attributes["duration"]
      when "chat_session"
        chat_session = user.chat_sessions.find_by(id: attributes["chat_session_id"])
        errors << error(:chat_session_required) unless chat_session
      when "job"
        job = Job.visible_to(user, scope: user.admin? ? Job.all : user.jobs).find_by(id: attributes["job_id"])
        errors << error(:job_required) unless job
      end
      [ chat_session, job ]
    end

    def evaluate(descriptor, role:, repository:, scope:, constraints:, chat_session:, job:, errors:)
      return [ nil, nil ] unless attributes["policy"] == "allow"

      grant = AuthorityGrant.build(
        duration: attributes["duration"].to_sym, descriptor:, owner: user, actor: user, role:,
        subject_selector_type: attributes["subject_selector_type"], subject_selector_id: attributes["subject_selector_id"],
        subject_repository: repository, resource_scope: scope, constraints:, context: { user: },
        rules: Management.new(user).rules.map(&:to_policy_rule), chat_session:, job:
      )
      evaluation = grant.evaluate!
      [ evaluation.decision, evaluation.expires_at ]
    rescue AuthorityGrant::CeilingExceeded => e
      errors << error(:exceeds_policy_ceiling, rule: e.decision.decisive_rule&.id)
      [ nil, nil ]
    rescue ArgumentError
      errors << error(:rejected_by_policy)
      [ nil, nil ]
    end

    def persist!(actor, resolved)
      management = Management.new(user)
      payload = attributes.compact.merge("resource_scope" => resolved.scope, "role" => resolved.role,
        "constraints" => resolved.attributes["constraints"])
      case attributes["policy"]
      when "deny" then management.deny!(payload, actor:)
      when "ask" then management.ask!(payload, actor:)
      else
        attributes["duration"] == "permanent" ? management.grant!(payload, actor:) : management.lease!(payload, actor:)
      end
    end

    def invalid_preview(errors)
      Preview.new(valid: false, errors:, warnings: [], draft: nil, summary: nil, ceiling: nil, examples: nil, digest: nil)
    end

    def error(code, **details)
      { code: code.to_s, message: I18n.t("api.permission_rule_drafts.errors.#{code}", **details), details: }
    end

    def public_draft(resolved)
      attrs = resolved.attributes
      {
        policy: attrs["policy"], duration: attrs["duration"], role: resolved.role,
        subject: { type: attrs["subject_selector_type"], id: attrs["subject_selector_id"],
                   subject_type: attrs["subject_type"], repository_id: resolved.repository&.id },
        capability: resolved.descriptor.capability, operation: resolved.descriptor.operation,
        resource_scope: ToolPayloadRedactor.redact(resolved.scope),
        resource_scope_label: scope_label(resolved),
        constraints: ToolPayloadRedactor.redact(attrs["constraints"]),
        chat_session_id: resolved.chat_session&.id, job_id: resolved.job&.id,
        expires_at: resolved.expires_at&.iso8601, rationale: attrs["rationale"]
      }
    end

    def scope_label(resolved)
      result = resolved.descriptor.resource_scope.label(resolved.scope, context: { user: })
      ToolPayloadRedactor.redact(result.success? ? result.value : resolved.scope.to_json)
    end

    def summary_for(resolved)
      attrs = resolved.attributes
      descriptor = resolved.descriptor
      subject = subject_label(resolved)
      scope = scope_label(resolved)
      constraints = attrs["constraints"].map { |key, value| "#{key} = #{ToolPayloadRedactor.redact(value)}" }
      allows = [ I18n.t("api.permission_rule_drafts.summary.allows.#{attrs['policy']}", subject:,
        operation: descriptor.operation, resource: scope, duration: duration_label(resolved)) ]
      allows << I18n.t("api.permission_rule_drafts.summary.only_when", constraints: constraints.join(", ")) if constraints.any?
      excludes = [ I18n.t("api.permission_rule_drafts.summary.excludes.other_operations") ]
      excludes << I18n.t("api.permission_rule_drafts.summary.excludes.other_scopes", resource: scope) if resolved.scope.present?
      excludes << I18n.t("api.permission_rule_drafts.summary.excludes.other_subjects", subject:)
      excludes << I18n.t("api.permission_rule_drafts.summary.excludes.ceilings")
      excludes << I18n.t("api.permission_rule_drafts.summary.excludes.expires") unless attrs["duration"] == "permanent"
      { allows:, excludes: }
    end

    def duration_label(resolved)
      I18n.t("api.permission_rule_drafts.summary.durations.#{resolved.attributes['duration']}")
    end

    def subject_label(resolved)
      attrs = resolved.attributes
      id = attrs["subject_selector_id"]
      key = attrs["subject_selector_type"]
      I18n.t("api.permission_rule_drafts.summary.subjects.#{key}", id: id, default: key)
    end

    def ceiling_for(resolved)
      rule = resolved.decision&.decisive_rule
      rule = nil if rule&.id == "proposed-authority"
      {
        maximum_autonomy: resolved.descriptor.maximum_autonomy.to_s,
        maximum_duration_seconds: resolved.descriptor.maximum_duration&.to_i,
        permanent_allowed: resolved.descriptor.authority_durations.include?(:permanent) && resolved.descriptor.maximum_autonomy == :permanent,
        limited_by: rule && { id: rule.id, layer: rule.layer.to_s, policy: rule.policy.to_s }
      }
    end

    # Representative calls the rule does and does not cover, phrased from the
    # same normalized subject/operation/scope the evaluator will see.
    def examples_for(resolved)
      attrs = resolved.attributes
      subject = subject_label(resolved)
      operation = resolved.descriptor.operation
      scope = scope_label(resolved)
      key = "api.permission_rule_drafts.examples"
      matches = [ I18n.t("#{key}.matches.exact", subject:, operation:, resource: scope) ]
      matches << I18n.t("#{key}.matches.constrained", constraints: attrs["constraints"].map { |k, v| "#{k} = #{ToolPayloadRedactor.redact(v)}" }.join(", ")) if attrs["constraints"].present?
      non_matches = [ I18n.t("#{key}.non_matches.other_operation", subject:, operation:) ]
      non_matches << I18n.t("#{key}.non_matches.other_resource", subject:, operation:, resource: scope) if resolved.scope.present?
      non_matches << I18n.t("#{key}.non_matches.other_subject", operation:, subject:)
      non_matches << I18n.t("#{key}.non_matches.after_expiry") unless attrs["duration"] == "permanent"
      { matches:, non_matches: }
    end

    def warnings_for(resolved)
      return [] if @request_scope.nil?

      relation = resolved.descriptor.resource_scope.compare(resolved.scope, @request_scope, context: { user: })
      value = relation.success? ? relation.value : :disjoint
      return [] if %i[equal narrower].include?(value)

      [ { code: value == :broader ? "scope_broader_than_request" : "scope_not_covering_request",
          message: I18n.t("api.permission_rule_drafts.warnings.#{value == :broader ? 'scope_broader_than_request' : 'scope_not_covering_request'}") } ]
    end

    # Binds the preview to every input that determines whether and how the draft
    # applies: the normalized draft, the descriptor contract and the owner's
    # active rules (a changed ceiling or an upgraded descriptor goes stale).
    def digest_for(resolved)
      rules_state = Management.new(user).rules.pluck(:id, :updated_at, :policy).map { |id, at, policy| [ id, at.to_f, policy ] }
      material = {
        user: user.id, draft: resolved.attributes.except("rationale").merge("resource_scope" => resolved.scope),
        descriptor: Digest::SHA256.hexdigest(JSON.generate(resolved.descriptor.contract_key.map(&:to_s))),
        role: resolved.role, rules: rules_state
      }
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, JSON.generate(deep_sort(material)))
    end

    def deep_sort(value)
      case value
      when Hash then value.to_h { |key, item| [ key.to_s, deep_sort(item) ] }.sort.to_h
      when Array then value.map { |item| deep_sort(item) }
      else value
      end
    end
  end
end
