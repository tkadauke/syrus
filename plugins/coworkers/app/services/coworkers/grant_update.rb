class Coworkers::GrantUpdate
  ConfirmationRequired = Class.new(StandardError)

  def self.call(...) = new(...).call

  def initialize(owner:, coworker:, capability:, approval_policy:, constraints: {}, confirmed: false)
    @owner = owner
    @coworker = coworker
    @capability = capability.to_s
    @approval_policy = approval_policy.to_s
    @constraints = constraints.to_h
    @confirmed = ActiveModel::Type::Boolean.new.cast(confirmed)
  end

  def call
    raise Pundit::NotAuthorizedError unless @owner.is_a?(User) && @coworker.owner_user_id == @owner.id
    raise ArgumentError, "unknown capability" unless Coworkers::Create::DEFAULT_GRANTS.key?(@capability)

    target = Coworkers::GrantPolicy.for(@approval_policy)
    grant = @coworker.grants.find_by(capability: @capability)
    current = grant&.approval_policy || "off"
    constraints_escalated = constraints_more_permissive?(grant)
    if (target.escalation_from?(current) || constraints_escalated) && !@confirmed
      raise ConfirmationRequired, "grant escalation requires confirmation"
    end

    Coworkers::Grant.transaction do
      if @approval_policy == "off"
        grant&.destroy!
      else
        grant ||= @coworker.grants.build(capability: @capability)
        grant.update!(approval_policy: @approval_policy, constraints: normalized_constraints)
      end
    end
  end

  private

  def normalized_constraints
    return {} unless @capability == "workspace.files"

    paths = Array(@constraints["confirm_paths"] || @constraints[:confirm_paths]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    paths.empty? ? {} : { "confirm_paths" => paths }
  end

  def constraints_more_permissive?(grant)
    return false if @approval_policy == "off"
    return false unless @capability == "workspace.files" && grant

    current_paths = Array(grant.constraints["confirm_paths"]).map(&:to_s).to_set
    target_paths = Array(normalized_constraints["confirm_paths"]).map(&:to_s).to_set
    (current_paths - target_paths).any?
  end
end
