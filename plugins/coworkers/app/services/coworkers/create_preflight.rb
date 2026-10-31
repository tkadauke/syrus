class Coworkers::CreatePreflight
  Result = Data.define(:handle, :remote, :grants)

  def initialize(owner:, name:, handle:, workspace_repo:, accent_hex: nil, avatar_key: nil,
                 chat_provider: nil, chat_model: nil, chat_effort: nil, grants: nil,
                 remote_workspace: nil, test_push: true)
    @owner = owner
    @name = name
    @handle = HandleRegistry.normalize(handle)
    @workspace_repo = workspace_repo
    @attributes = { accent_hex: accent_hex, avatar_key: avatar_key, chat_provider: chat_provider,
                    chat_model: chat_model, chat_effort: chat_effort }.compact
    @requested_grants = grants
    @remote_workspace = remote_workspace
    @test_push = test_push
  end

  def call
    validate_record!
    validate_model!
    validate_grants!
    raise Coworkers::Create::BranchExists, "#{branch} already exists" if remote.branch_exists?(branch)
    remote.test_push_access! if @test_push
    Result.new(handle: @handle, remote: remote, grants: selected_grants)
  end

  private

  def branch = "coworkers/#{@handle}"

  def validate_record!
    candidate = Coworkers::Coworker.new({ owner_user: @owner, name: @name, handle: @handle,
      workspace_repo: @workspace_repo }.merge(@attributes))
    candidate.validate!
    raise ActiveRecord::RecordInvalid, candidate if Handle.exists?(handle: @handle)
  end

  def validate_grants!
    unknown = normalized_requested_grants.map { |grant| grant.fetch(:capability) } - Coworkers::GrantCatalog.names
    raise ArgumentError, "unknown grants: #{unknown.join(', ')}" if unknown.any?
    normalized_requested_grants.each do |grant|
      descriptor = Coworkers::GrantCatalog.fetch(grant.fetch(:capability))
      raise ArgumentError, "scope is required for #{descriptor.name}" if descriptor.scopeable? && grant[:scope].nil?
      raise ArgumentError, "invalid scope for #{descriptor.name}" unless descriptor.valid_scope?(grant[:scope], user: @owner)
      raise ArgumentError, "scope is not supported for #{descriptor.name}" if !descriptor.scopeable? && grant[:scope].present?
    end
  end

  def validate_model!
    provider = @attributes[:chat_provider]
    model = @attributes[:chat_model]
    raise ArgumentError, "chat_provider is required when chat_model is set" if model.present? && provider.blank?
    return if provider.blank?
    raise ArgumentError, "unknown chat provider: #{provider}" unless User.chat_providers.include?(provider)
    raise ArgumentError, "chat provider is not configured: #{provider}" unless @owner.chat_provider_configured?(provider)
    return if model.blank?

    available = Array(AgentProviders.for(provider).available_models).map { |entry| entry.respond_to?(:id) ? entry.id : entry.to_s }
    raise ArgumentError, "unknown chat model for #{provider}: #{model}" unless available.include?(model)
  rescue AgentProviders::ConfigurationError
    raise ArgumentError, "chat provider is not configured: #{provider}"
  end

  def selected_grants
    unless @requested_grants
      defaults = Coworkers::Create::DEFAULT_GRANTS.merge(McpToolRegistry.default_coworker_grants)
      return defaults.map { |name, policy| { capability: name, approval_policy: policy, scope: nil } }
    end
    normalized_requested_grants.map do |grant|
      name = grant.fetch(:capability)
      grant.merge(approval_policy: Coworkers::Create::DEFAULT_GRANTS.fetch(name) { Coworkers::GrantCatalog.fetch(name).default_policy })
    end
  end

  def normalized_requested_grants
    @normalized_requested_grants ||= Array(@requested_grants).map do |raw|
      if raw.respond_to?(:to_h)
        attributes = raw.to_h.symbolize_keys
        { capability: (attributes[:capability] || attributes[:name]).to_s, scope: attributes[:scope] }
      else
        { capability: raw.to_s, scope: nil }
      end
    end.uniq
  end

  def remote
    @remote ||= @remote_workspace || begin
      match = @workspace_repo.to_s.strip.match(%r{\A(?:https://github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?/?\z}i)
      raise Coworkers::Create::InvalidRemote, "workspace_repo must be a GitHub repository URL" unless match
      Coworkers::RemoteWorkspace.new(owner: match[1], name: match[2], user: @owner)
    end
  end
end
