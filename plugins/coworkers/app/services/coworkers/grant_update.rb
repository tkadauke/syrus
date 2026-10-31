class Coworkers::GrantUpdate
  ConfirmationRequired = Class.new(StandardError)
  SCOPE_UNCHANGED = Object.new.freeze

  def self.call(...) = new(...).call

  def initialize(owner:, coworker:, capability:, approval_policy:, constraints: {}, scope: SCOPE_UNCHANGED, confirmed: false)
    @owner = owner
    @coworker = coworker
    @capability = capability.to_s
    @approval_policy = approval_policy.to_s
    @constraints = constraints.to_h
    @scope = scope
    @confirmed = ActiveModel::Type::Boolean.new.cast(confirmed)
  end

  def call
    raise Pundit::NotAuthorizedError unless @owner.is_a?(User) && @coworker.owner_user_id == @owner.id
    descriptor = Coworkers::GrantCatalog.fetch(@capability)
    raise ArgumentError, "approval policy exceeds maximum #{descriptor.maximum_policy}" unless Coworkers::GrantCatalog.policy_allowed?(descriptor, @approval_policy)

    target = Coworkers::GrantPolicy.for(@approval_policy)
    grant = @coworker.grants.find_by(capability: @capability)
    return grant&.destroy! if @approval_policy == "off"
    scope = @scope.equal?(SCOPE_UNCHANGED) ? grant&.scope : @scope
    raise ArgumentError, "invalid scope for #{@capability}" unless descriptor.valid_scope?(scope, user: @owner)
    current = grant&.approval_policy || "off"
    scope_escalated = grant && descriptor.scopeable? && grant.scope != scope
    constraints_escalated = constraints_more_permissive?(grant)
    if (target.escalation_from?(current) || constraints_escalated || scope_escalated) && !@confirmed
      raise ConfirmationRequired, "grant escalation requires confirmation"
    end

    Coworkers::Grant.transaction do
      grant ||= @coworker.grants.build(capability: @capability)
      grant.update!(approval_policy: @approval_policy, constraints: normalized_constraints, scope: scope)
    end
  end

  private

  def normalized_constraints
    if @capability == "coworker.spawn_chat"
      defaults = {
        "max_spawns_per_run" => Coworkers::SpawnChatTool::DEFAULT_PER_RUN_CAP,
        "max_spawns_per_day" => Coworkers::SpawnChatTool::DEFAULT_PER_DAY_CAP
      }
      return defaults.each_with_object({}) do |(key, fallback), result|
        value = Integer(@constraints[key] || @constraints[key.to_sym] || fallback, exception: false)
        raise ArgumentError, "#{key} must be a positive integer" unless value&.positive?
        result[key] = value
      end
    end
    return {} unless @capability == "workspace.files"

    paths = Array(@constraints["confirm_paths"] || @constraints[:confirm_paths]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    paths.empty? ? {} : { "confirm_paths" => paths }
  end

  def constraints_more_permissive?(grant)
    return false if @approval_policy == "off"
    return false unless grant
    if @capability == "coworker.spawn_chat"
      current = {
        "max_spawns_per_run" => Coworkers::SpawnChatTool::DEFAULT_PER_RUN_CAP,
        "max_spawns_per_day" => Coworkers::SpawnChatTool::DEFAULT_PER_DAY_CAP
      }.merge(grant.constraints.to_h)
      target = normalized_constraints
      return %w[max_spawns_per_run max_spawns_per_day].any? do |key|
        target.fetch(key) > current.fetch(key, 0).to_i
      end
    end
    return false unless @capability == "workspace.files"

    current_paths = Array(grant.constraints["confirm_paths"]).map(&:to_s).to_set
    target_paths = Array(normalized_constraints["confirm_paths"]).map(&:to_s).to_set
    (current_paths - target_paths).any?
  end
end
