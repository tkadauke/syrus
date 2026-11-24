require "rails_helper"

RSpec.describe "Syrus::Host facades replacing legacy plugin constants" do
  it "mirrors the agent role identifiers exactly" do
    Syrus::Host::AgentRoles.constants.each do |name|
      expect(Syrus::Host::AgentRoles.const_get(name)).to eq(AgentRole.const_get(name))
    end
  end

  it "registers a contract with every member resolvable for each new facade" do
    names = %w[AgentRoles ChatMessages ChatPendingActions ChatDelivery ChatTurns ChatWorkspaces Handles PermissionRules
               PermissionLeases PermissionPolicies DiffReviews RetentionLimits PluginJob ReviewerTargets AdversarialReviewStep
               RetentionExecutor RetentionResult RetentionDefinition WorkLauncher WorkGateResult WorkDefinition
               PermissionCapabilityDescriptor PermissionCapabilityAdapter PermissionCatalog PermissionManagement
               PendingActionBase]
    names.each do |name|
      api = Syrus::Host.apis.find { |candidate| candidate.name == "Syrus::Host::#{name}" }
      expect(api).to be_present, name
      expect(api.since).to eq("0.1.16")
      constant = api.name.constantize
      api.members.each do |member|
        expect(constant.respond_to?(member) || constant.method_defined?(member) || constant.const_defined?(member) || constant.allocate.respond_to?(member)).to be(true), "#{name} lacks #{member}"
      end
    end
  end

  it "resolves aliases to the core constants before the prepare hook installs them" do
    expect(Syrus::Host::PluginJob).to equal(::PluginJob)
    expect(Syrus::Host::ReviewerTargets::TargetRequired).to equal(::ReviewerTargets::TargetRequired)
    expect(Syrus::Host::WorkLauncher::LockConflict).to equal(::WorkUnits::Launcher::LockConflict)
    expect(Syrus::Host::PermissionCatalog::UnknownCapability).to equal(::Permissions::Catalog::UnknownCapability)
  end

  it "ranks policies the way the core evaluator does" do
    Permissions::PolicyEvaluator::POLICY_RANK.each do |policy, rank|
      expect(Syrus::Host::PermissionPolicies.rank(policy)).to eq(rank)
      expect(Syrus::Host::PermissionPolicies.rank(policy.to_s)).to eq(rank)
    end
    expect { Syrus::Host::PermissionPolicies.rank(:nope) }.to raise_error(KeyError)
  end

  it "forwards the delegating query facades" do
    expect(Syrus::Host::ChatMessages.none).to be_empty
    expect(Syrus::Host::PermissionRules.where(id: 0)).to be_empty
    expect(Syrus::Host::PermissionLeases.where(id: 0)).to be_empty
    expect(Syrus::Host::ChatPendingActions.where(id: 0)).to be_empty
    expect(Syrus::Host::DiffReviews.comments.none).to be_empty
    expect(Syrus::Host::DiffReviews.versions.where(id: 0)).to be_empty
    expect(Syrus::Host::Handles.normalize("  AbC ")).to eq(HandleRegistry.normalize("  AbC "))
  end

  it "delegates delivery, turns, limits, and workspace helpers" do
    chat = instance_double(ChatSession)
    allow(ChatQueuedMessagePromoter).to receive(:deliver_one_if_idle!)
    Syrus::Host::ChatDelivery.deliver_next_if_idle!(chat)
    expect(ChatQueuedMessagePromoter).to have_received(:deliver_one_if_idle!).with(chat)
    expect(Syrus::Host::ChatDelivery.internal_role_key).to eq(ChatQueuedMessage::INTERNAL_ROLE_KEY)

    allow(ChatTurnJob).to receive(:perform_later)
    Syrus::Host::ChatTurns.enqueue(1, 2)
    expect(ChatTurnJob).to have_received(:perform_later).with(1, 2)

    expect(Syrus::Host::RetentionLimits.default_batch_size).to eq(RetentionPruner::DEFAULT_BATCH_SIZE)
    expect(Syrus::Host::RetentionLimits.default_max_batches).to eq(RetentionPruner::DEFAULT_MAX_BATCHES)

    allow(ChatWorkspace).to receive(:repo_path_for).and_return(Pathname.new("/tmp/x"))
    expect(Syrus::Host::ChatWorkspaces.repo_path_for(chat, nil)).to eq(Pathname.new("/tmp/x"))
  end

  it "installs and removes the after-commit-on-create observer" do
    mod = Module.new { def noop_callback = nil }
    allow(ChatMessage).to receive(:include)
    allow(ChatMessage).to receive(:set_callback)
    allow(ChatMessage).to receive(:skip_callback)
    Syrus::Host::ChatMessages.install_after_commit_on_create(mod, :noop_callback)
    Syrus::Host::ChatMessages.remove_after_commit_on_create(:noop_callback)
    expect(ChatMessage).to have_received(:set_callback).with(:commit, :after, :noop_callback, on: :create)
    expect(ChatMessage).to have_received(:skip_callback).with(:commit, :after, :noop_callback, on: :create)
  end

  it "keeps the legacy allowlist free of stale entries and records reasons" do
    surface = Syrus::PluginHostSurface.new
    expect(surface.lookup("Job").reason).to be_present
    expect(surface.legacy_baseline).to eq(surface.legacy_entries.size)
  end

  describe "service aliases for the coworkers, review and briefing plugins" do
    {
      Memory: "Syrus::Memory", PromptsMemoryContext: "Prompts::MemoryContext",
      PromptsAdversarialReview: "Prompts::AdversarialReview", McpAuthorizationSupport: "Mcp::Tools::AuthorizationSupport",
      McpPendingActionToolSupport: "Mcp::Tools::PendingActionToolSupport", McpProposalToolSupport: "Mcp::Tools::ProposalToolSupport",
      McpEvidenceRedactor: "Mcp::Tools::EvidenceRedactor", McpPagination: "Mcp::Pagination", ChatBridgeThread: "ChatBridgeThread",
      Mentionable: "Mentionable", MentionablesResolver: "Mentionables::Resolver", ColorPalette: "Appearance::ColorPalette",
      CommandRedactor: "CommandRedactor", Paginatable: "Paginatable", ChatLockErrors: "ChatLockErrors"
    }.each do |name, target|
      it "aliases #{name} to #{target} with a contract whose members resolve" do
        constant = Syrus::Host.const_get(name)
        expect(constant).to equal(target.constantize)
        api = Syrus::Host.apis.find { |candidate| candidate.name == "Syrus::Host::#{name}" }
        expect(api).to be_present
        api.members.each do |member|
          expect(constant.respond_to?(member) || constant.method_defined?(member) || constant.const_defined?(member)).to be(true), "#{name} lacks #{member}"
        end
      end
    end
  end
end
