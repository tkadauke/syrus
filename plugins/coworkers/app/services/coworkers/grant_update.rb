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
    Coworkers::PrivilegedGrantGate.ensure_available!(descriptor) unless @approval_policy == "off"
    raise ArgumentError, "approval policy exceeds maximum #{descriptor.maximum_policy}" unless Coworkers::GrantCatalog.policy_allowed?(descriptor, @approval_policy)

    target = Coworkers::GrantPolicy.for(@approval_policy)
    current_entry = @coworker.permission_rules.entries.find { |entry| entry.fetch(:capability) == @capability }
    current_entry ||= { approval_policy: "off", constraints: {}, scope: nil }
    scope = @scope.equal?(SCOPE_UNCHANGED) ? current_entry[:scope] : @scope
    raise ArgumentError, "invalid scope for #{@capability}" unless descriptor.valid_scope?(scope, user: @owner)
    current = current_entry.fetch(:approval_policy)
    scope_escalated = current != "off" && descriptor.scopeable? && current_entry[:scope] != scope
    constraints_escalated = constraints_more_permissive?(current_entry)
    if (target.escalation_from?(current) || constraints_escalated || scope_escalated) && !@confirmed
      raise ConfirmationRequired, "grant escalation requires confirmation"
    end

    @coworker.permission_rules.update!(capability: @capability, approval_policy: @approval_policy,
      constraints: normalized_constraints, scope:, actor: @owner, provenance: { "coworker_grant_editor" => true })
  end

  private

  def normalized_constraints
    if @capability.in?([ "coworker.spawn_chat", "syrus.spawn_chat" ])
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

    paths = Array(@constraints["confirm_paths"] || @constraints[:confirm_paths]).filter_map do |path|
      path = path.to_s.strip
      next if path.blank?

      normalized_workspace_path(path)
    end.uniq
    paths.empty? ? {} : { "confirm_paths" => paths }
  end

  def constraints_more_permissive?(entry)
    return false if @approval_policy == "off"
    return false if entry[:approval_policy] == "off"
    if @capability.in?([ "coworker.spawn_chat", "syrus.spawn_chat" ])
      current = {
        "max_spawns_per_run" => Coworkers::SpawnChatTool::DEFAULT_PER_RUN_CAP,
        "max_spawns_per_day" => Coworkers::SpawnChatTool::DEFAULT_PER_DAY_CAP
      }.merge(entry[:constraints].to_h)
      target = normalized_constraints
      return %w[max_spawns_per_run max_spawns_per_day].any? do |key|
        target.fetch(key) > current.fetch(key, 0).to_i
      end
    end
    return false unless @capability == "workspace.files"

    current_paths = Array(entry[:constraints]["confirm_paths"]).map { |path| normalized_workspace_path(path) }.to_set
    target_paths = Array(normalized_constraints["confirm_paths"]).map(&:to_s).to_set
    (current_paths - target_paths).any?
  end

  def normalized_workspace_path(path)
    relative_path = Pathname.new(path.to_s)
    raise ArgumentError, "confirm_paths must be relative workspace paths" if relative_path.absolute?

    clean = relative_path.cleanpath
    if clean.to_s == ".." || clean.each_filename.first.in?([ "..", ".git" ])
      raise ArgumentError, "confirm_paths must stay inside the coworker workspace"
    end
    clean.to_s
  end
end
