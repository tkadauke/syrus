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

  describe "service aliases for the coworkers, review and briefing plugins" do
    {
      Memory: "Syrus::Memory", MemoryStore: "Syrus::Plugin::MemoryStore", PromptsMemoryContext: "Prompts::MemoryContext",
      PromptsAdversarialReview: "Prompts::AdversarialReview", McpAuthorizationSupport: "Mcp::Tools::AuthorizationSupport",
      McpPendingActionToolSupport: "Mcp::Tools::PendingActionToolSupport", McpProposalToolSupport: "Mcp::Tools::ProposalToolSupport",
      McpEvidenceRedactor: "Mcp::Tools::EvidenceRedactor", McpPagination: "Mcp::Pagination",
      Mentionable: "Mentionable", MentionablesResolver: "Mentionables::Resolver", ColorPalette: "Appearance::ColorPalette",
      CommandRedactor: "CommandRedactor", Paginatable: "Paginatable", ChatLockErrors: "ChatLockErrors"
    }.each do |name, target|
      it "aliases #{name} to #{target} with a contract whose members resolve" do
        constant = Syrus::Host.const_get(name)
        expect(constant).to equal(target.constantize)
        api = Syrus::Host.apis.find { |candidate| candidate.name == "Syrus::Host::#{name}" }
        expect(api).to be_present
        api.members.each do |member|
          exists = constant.respond_to?(member) || constant.method_defined?(member) || constant.private_method_defined?(member) ||
            (member.match?(/\A[A-Z]/) && constant.const_defined?(member))
          expect(exists).to be(true), "#{name} lacks #{member}"
        end
      end
    end
  end

  describe "plugin-point and service aliases for the remaining plugin references" do
    %w[SidebarPage McpToolSet ChatIdentityProvider ChatMcpToolSet ChatPayloadContributor ChatTurnFinalizer ChatTurnLifecycle
       ChatTurnOrientation ChatWorkspaceLifecycle DiffReviewAnnotationProvider JobVisibilityRestriction McpRunContextContributor
       PostImplementationReviewProvider RepositoryConfiguration RepositoryFilter RetentionPolicy ReviewContextContributor
       ReviewGate ReviewPresentationContributor ReviewerTargetProvider UiSlot].each do |name|
      it "aliases #{name} to the plugin point it names" do
        expect(Syrus::Host.const_get(name)).to equal("Syrus::Plugin::#{name}".constantize)
        expect(Syrus::Host.apis.map(&:name)).to include("Syrus::Host::#{name}")
      end
    end

    {
      GitRunner: "GitRunner", SyrusYml: "SyrusYml", RepositoryContent: "RepositoryContent",
      WorkflowWorkspace: "WorkflowWorkspace", DataCleanup: "Syrus::DataCleanup", PathJail: "Syrus::PathJail",
      AgentProviders: "AgentProviders", StepBase: "Steps::Base", WorkflowBase: "Workflows::Base",
      McpToolRegistry: "McpToolRegistry", ApplicationPolicy: "ApplicationPolicy", RunJob: "RunJob",
      AppEvents: "AppEvents", InvestigationJobCreator: "InvestigationJobs::Creator",
      AdversarialReviewProjects: "App::AdversarialReviewProjects", ReviewNoteProjects: "App::ReviewNoteProjects",
      JobDiscussionChatResolver: "App::JobDiscussionChatResolver"
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

  describe "query and operation facades" do
    let(:user) { User.create!(email_address: "facade-#{SecureRandom.hex(4)}@example.com", password: "password123") }

    it "registers a contract with every member resolvable for each facade" do
      %w[Jobs Repositories Users Runs Workflows Epics ChatSessions ChatBridge AdminActions ActivityRecords FeatureFlags
         PluginRecords ChatSearch InstanceWorkers Settings RepositoryAccess].each do |name|
        api = Syrus::Host.apis.find { |candidate| candidate.name == "Syrus::Host::#{name}" }
        expect(api).to be_present, name
        constant = api.name.constantize
        api.members.each do |member|
          expect(constant.respond_to?(member) || constant.const_defined?(member)).to be(true), "#{name} lacks #{member}"
        end
      end
    end

    it "does not expose model classes as constants of the facades" do
      expect(Syrus::Host::Jobs).not_to equal(::Job)
      expect(Syrus::Host::ChatSessions).not_to equal(::ChatSession)
      expect(Syrus::Host.const_defined?(:ChatBridgeThread, false)).to be(false)
    end

    it "returns relations and plain values for job, repository, user, run, workflow, and epic queries" do
      expect(Syrus::Host::Jobs.where(id: 0)).to be_empty
      expect(Syrus::Host::Jobs.none).to be_empty
      expect(Syrus::Host::Jobs.all.to_sql).to eq(Job.all.to_sql)
      expect(Syrus::Host::Jobs.visible_to(user, scope: Job.none)).to be_empty
      expect(Syrus::Host::Jobs.terminal_states).to eq(Job::TERMINAL_STATES)
      expect(Syrus::Host::Jobs.user_facing_kinds).to eq(Job::Kind.user_facing_values)
      expect(Syrus::Host::Jobs.priority_rank("medium")).to eq(Job.priority_rank("medium"))
      expect(Syrus::Host::Repositories.accessible_repository_ids_for(user)).to eq(Repository.accessible_repository_ids_for(user))
      expect(Syrus::Host::Repositories.build(owner: "o", name: "n")).to be_a(Repository).and be_new_record
      expect(Syrus::Host::Users.find(user.id)).to eq(user)
      expect(Syrus::Host::Users.count).to eq(User.count)
      expect(Syrus::Host::Users.user?(user)).to be(true)
      expect(Syrus::Host::Users.user?(Object.new)).to be(false)
      expect(Syrus::Host::Runs.where(id: 0)).to be_empty
      expect(Syrus::Host::Workflows.where(id: 0)).to be_empty
      expect(Syrus::Host::Workflows.resume_queue_name("host-a")).to eq(Workflow.resume_queue_name("host-a"))
      expect(Syrus::Host::Epics.where(id: 0)).to be_empty
      expect(Syrus::Host::Epics.archived_state).to eq(Epic::ARCHIVED_STATE)
    end

    it "names the activity record relations" do
      expect(Syrus::Host::ActivityRecords.job_approvals.klass).to eq(JobApproval)
      expect(Syrus::Host::ActivityRecords.state_transitions.klass).to eq(StateTransition)
      expect(Syrus::Host::ActivityRecords.pr_review_comments.klass).to eq(PrReviewComment)
      expect(Syrus::Host::ActivityRecords.chat_proposals.klass).to eq(ChatProposal)
      expect(Syrus::Host::ActivityRecords.ui_engagement_samples.klass).to eq(UiEngagementSample)
      expect(Syrus::Host::ActivityRecords.job_logs.klass).to eq(JobLog)
      expect(Syrus::Host::ActivityRecords.chat_spend_entries.klass).to eq(ChatSpendEntry)
      expect(Syrus::Host::ActivityRecords.steps.klass).to eq(Step)
      expect(Syrus::Host::ActivityRecords.spawned_processes.klass).to eq(SpawnedProcess)
    end

    it "writes and reads audit entries" do
      Syrus::Host::AdminActions.log!(user: user, action: "facade_probe", params: { reason: "spec" })
      expect(Syrus::Host::AdminActions.where(action: "facade_probe").count).to eq(1)
    end

    it "delegates settings, flags, plugin records, workers, search, and repository access" do
      allow(AppSetting).to receive(:ui_engagement_telemetry_enabled?).and_return(true)
      expect(Syrus::Host::Settings.ui_engagement_telemetry_enabled?).to be(true)

      allow(Feature).to receive(:public_send).and_call_original
      allow(Feature).to receive(:public_send).with("facade_probe_enabled?").and_return(true)
      expect(Syrus::Host::FeatureFlags.enabled?("facade_probe")).to be(true)

      record = Syrus::Host::PluginRecords.ensure!("facade_probe")
      expect(Syrus::Host::PluginRecords.find_by_name("facade_probe")).to eq(record)
      expect(Syrus::Host::PluginRecords.find_by_name("missing_probe")).to be_nil

      freeze_time do
        expect(Syrus::Host::InstanceWorkers.fresh.to_sql).to eq(InstanceVersion.fresh.where(role: "worker").to_sql)
      end

      # The FTS index table is not part of the test schema, so stub the boundary.
      stub_const("ChatMessageSearchIndex", double(top_matches_by_chat_session: { 1 => 2 }))
      expect(Syrus::Host::ChatSearch.top_matches_by_chat_session("q")).to eq({ 1 => 2 })

      policy = instance_double(RepositoryPolicy, write?: true)
      allow(RepositoryPolicy).to receive(:new).with(user, :repo).and_return(policy)
      expect(Syrus::Host::RepositoryAccess.write?(user, :repo)).to be(true)
    end

    it "claims and checks handles through the handle facade" do
      expect(Syrus::Host::Handles::FORMAT).to equal(Handle::FORMAT)
      expect(Syrus::Host::Handles.taken?("facade_free_handle")).to be(false)
    end

    it "extends the chat session model through the host hook" do
      Syrus::Host::ChatSessions.extend_model { define_method(:facade_probe) { :probed } }
      expect(ChatSession.new.facade_probe).to eq(:probed)
    ensure
      Syrus::Host::ChatSessions.extend_model { remove_method(:facade_probe) if instance_methods(false).include?(:facade_probe) }
    end

    describe Syrus::Host::ChatBridge do
      let(:origin) { ChatSession.create!(user: user, title: "Origin") }
      let(:target) { ChatSession.create!(user: user, title: "Target") }

      it "opens a thread, delivers the prompt, finds it, and replies within it" do
        thread = described_class.open!(origin_chat: origin, target_chat: target, opened_by: user, prompt: "hello")

        expect(thread).to be_persisted
        expect(thread.origin_chat_session).to eq(origin)
        expect(thread.target_chat_session).to eq(target)
        expect(thread.hop_count).to eq(1)
        expect(described_class.find_thread(thread.id)).to eq(thread)
        expect(described_class.find_thread(0)).to be_nil

        result = described_class.reply!(thread: thread, text: "answer", from: target)
        expect(result.fetch(:outbound_message)).to be_present
      end

      it "raises ClosedThreadError when replying to a closed thread" do
        thread = described_class.open!(origin_chat: origin, target_chat: target, opened_by: user, prompt: "hello")
        thread.close!

        expect { described_class.reply!(thread: thread, text: "late", from: target) }.to raise_error(described_class::ClosedThreadError)
      end
    end
  end
end
