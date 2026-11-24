require "rails_helper"

RSpec.describe Syrus::Host::PublicApis do
  around do |example|
    original_apis = Syrus::Host.apis.dup
    example.run
  ensure
    described_class.install!
    Syrus::Host.apis.replace(original_apis)
  end

  it "rebuilds aliases and contracts without duplicates on every prepare pass" do
    2.times { described_class.install! }

    expect(Syrus::Host.apis.size).to eq(206)
    expect(Syrus::Host.apis.map(&:name).uniq.size).to eq(206)
    expect(Syrus::Host::Record).to equal(ApplicationRecord)
    expect(Syrus::Host::BackgroundJob).to equal(ApplicationJob)
    expect(Syrus::Host::PluginInvocation).to equal(Syrus::PluginInvocation)
    expect(Syrus::Host::BackupArtifactSource).to equal(Syrus::Plugin::BackupArtifactSource)
    expect(Syrus::Host::BackupDestination).to equal(Syrus::Plugin::BackupDestination)
    expect(Syrus::Host::SystemAlertProvider).to equal(Syrus::Plugin::SystemAlertProvider)
    expect(Syrus::Host::ExternalReviewer).to equal(Syrus::Plugin::ExternalReviewer)
    expect(Syrus::Host::ExternalReviewContext).to equal(Syrus::Plugin::ExternalReviewContext)
    expect(Syrus::Host::Toolkit).to equal(Syrus::Plugin::Toolkit)
  end

  it "aliases the ecosystem grader and workspace facades onto their core values" do
    {
      PluginApi: Syrus::PluginApi, GraderStep: SyrusYml::GradeStep, GraderBaseRetry: SyrusYml::BaseRetry,
      GraderResourceRequest: GraderResourceRequest, GraderExecutionCapabilities: TargetGraph::ExecutionCapabilities,
      TestRunResult: JunitXmlParser::ParsedRun, TestCaseResult: JunitXmlParser::ParsedCase,
      CoverageParseResult: CoverageAnalysis::Parsers::Base::ParseResult, WorkflowWorkspace: WorkflowWorkspace,
      GitRunner: GitRunner, CapabilityDescriptor: Permissions::CapabilityDescriptorAdapter
    }.each { |name, core| expect(Syrus::Host.const_get(name)).to equal(core), name.to_s }
  end

  it "exposes the shared grader defaults without the SyrusYml constants" do
    expect(Syrus::Host::GraderDefaults.default_phases).to equal(SyrusYml::DEFAULT_GRADE_PHASES)
    expect(Syrus::Host::GraderDefaults.max_timeout_minutes).to eq(SyrusYml::MAX_GRADE_TIMEOUT_MINUTES)
  end

  it "declares contracts for every promoted ecosystem facade" do
    names = %w[GraderStep GraderBaseRetry GraderDefaults GraderResourceRequest GraderExecutionCapabilities
               TestRunResult TestCaseResult CoverageParseResult WorkflowWorkspace GitRunner CapabilityDescriptor]
    names.each { |name| expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true), name }
    expect(Syrus::Host.apis.find { |api| api.name == "Syrus::Host::GraderResourceRequest" }.members).to include("ALL")
    expect(Syrus::Host.apis.find { |api| api.name == "Syrus::Host::McpTools" }.members).to include("run_from_context")
  end

  it "reads agent-runtime defaults from core without exposing the invocation engine" do
    runtime = Syrus::Host::AgentRuntime

    expect(runtime.default_timeout_seconds).to eq(AgentInvocation::DEFAULT_TIMEOUT_SECONDS)
    expect(runtime.silent_timeout_seconds).to eq(AgentInvocation::SILENT_TIMEOUT_SECONDS)
    expect(runtime.default_max_turns).to eq(AgentInvocation::DEFAULT_MAX_TURNS)
    expect(runtime.max_event_bytes).to eq(AgentInvocation::MAX_EVENT_BYTES)
    expect(runtime.forwarded_env_keys).to equal(AgentInvocation::ENV_FORWARD)
    expect { runtime.oversized_event_handler("Test").call(10) }.not_to raise_error
    expect(Syrus::Host::InvocationResult).to equal(AgentInvocation::Result)
    expect(Syrus::Host.public?("Syrus::Host::AgentRuntime")).to be(true)
  end

  it "backs every member of the agent-provider facades the agent plugins use" do
    {
      AgentRuntime: Syrus::Host::AgentRuntime, ProcessRunner: ProcessRunner, PerformanceLogging: PerformanceLogging,
      WorkflowWorkspace: WorkflowWorkspace, McpTools: Mcp::Tools, ToolContext: McpToolContext, Record: ApplicationRecord
    }.each do |name, target|
      api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::#{name}" }
      members = api.members.reject { |member| member.match?(/\A[A-Z]/) }
      singleton_members = members.select { |member| target.respond_to?(member) }
      expect(singleton_members).to include(*(%w[agent_mounts report_duration data_root agent_home_for utf8 write_log from_server_context transaction default_timeout_seconds] & members)), name.to_s
    end
  end

  it "aliases the source, execution, and speech-to-text contracts onto their core values" do
    {
      ExecutionBackend: Syrus::Plugin::ExecutionBackend, InputSource: Syrus::Plugin::InputSource,
      SourceControlProvider: Syrus::Plugin::SourceControlProvider, SpeechToTextProvider: Syrus::Plugin::SpeechToTextProvider,
      PlatformDelivery: Syrus::Plugin::PlatformDelivery, PurgeContributor: Syrus::Plugin::PurgeContributor,
      WorkerCapabilityProbe: Syrus::Plugin::WorkerCapabilityProbe,
      WorkflowArtifactContributor: Syrus::Plugin::WorkflowArtifactContributor,
      WorkspaceGitTransport: Syrus::Plugin::WorkspaceGitTransport, AgenticConnection: Syrus::Plugin::AgenticConnection,
      GatedToolSet: Syrus::Plugin::GatedToolSet, ContentSource: RepositoryContent::Source,
      ContentRevision: RepositoryContent::Revision, ContentEntry: RepositoryContent::Entry,
      ContentBlob: RepositoryContent::Blob, ContentChange: RepositoryContent::Change, ContentRef: RepositoryContent::Ref,
      ContentCommit: RepositoryContent::Commit, ContentCommitHistory: RepositoryContent::CommitHistory,
      ContentDivergence: RepositoryContent::Divergence, ContentError: RepositoryContent::Error,
      ContentNotFound: RepositoryContent::NotFound, ContentUnavailable: RepositoryContent::Unavailable,
      ContentUnknownRevision: RepositoryContent::UnknownRevision, ContentUnsupported: RepositoryContent::Unsupported,
      ContentTooLarge: RepositoryContent::TooLarge, ContentTruncated: RepositoryContent::Truncated,
      ExecutionBackendBase: Execution::Backend, LocalExecution: Execution::Local,
      SpeechToTextBase: ChatSpeechToText::Providers::Base, SpeechToTextError: ChatSpeechToText::Providers::TranscriptionError,
      SpeechToTextResult: ChatSpeechToText::Providers::TranscriptionResult,
      SpeechToTextInvalidAudio: ChatSpeechToText::Providers::InvalidAudio,
      SpeechToTextStreamingDelta: ChatSpeechToText::Providers::StreamingDelta,
      SpeechToTextTimeout: ChatSpeechToText::Providers::TranscriptionTimeout,
      SpeechToTextUnavailable: ChatSpeechToText::Providers::TranscriptionUnavailable,
      SpeechToTextTelemetry: ChatSpeechToText::Telemetry
    }.each do |name, core|
      expect(Syrus::Host.const_get(name)).to equal(core), name.to_s
      expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true), name.to_s
    end
  end

  it "backs every listed member of the value and telemetry facades with the core class" do
    {
      ContentBlob: %i[path bytes size truncated content_id], ContentEntry: %i[path type size content_id],
      ContentRevision: %i[id ref observed_at], ContentCommit: %i[sha message authored_at],
      ContentDivergence: %i[ahead behind]
    }.each do |name, members|
      api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::#{name}" }
      expect(api.members).to include(*members.map(&:to_s)), name.to_s
      expect(Syrus::Host.const_get(name).members).to include(*members), name.to_s
    end
    telemetry = Syrus::Host::SpeechToTextTelemetry
    Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::SpeechToTextTelemetry" }.members.each do |member|
      expect(telemetry).to respond_to(member)
    end
  end

  it "lists the extra McpTools and ProcessRunner members the source and infrastructure plugins call" do
    mcp = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::McpTools" }.members
    runner = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::ProcessRunner" }.members

    expect(mcp).to include("unauthorized", "truncate_text")
    expect(runner).to include("probe_mounts")
    expect(Mcp::Tools).to respond_to(:unauthorized, :truncate_text)
    expect(ProcessRunner).to respond_to(:probe_mounts)
  end

  it "aliases the review, chat and sidebar plugin-point facades onto their core modules" do
    {
      McpToolSet: Syrus::Plugin::McpToolSet, ChatMcpToolSet: Syrus::Plugin::ChatMcpToolSet,
      SidebarPage: Syrus::Plugin::SidebarPage, UiSlot: Syrus::Plugin::UiSlot,
      ChatIdentityProvider: Syrus::Plugin::ChatIdentityProvider,
      ChatPayloadContributor: Syrus::Plugin::ChatPayloadContributor,
      ChatTurnFinalizer: Syrus::Plugin::ChatTurnFinalizer, ChatTurnLifecycle: Syrus::Plugin::ChatTurnLifecycle,
      ChatTurnOrientation: Syrus::Plugin::ChatTurnOrientation,
      ChatWorkspaceLifecycle: Syrus::Plugin::ChatWorkspaceLifecycle,
      DiffReviewAnnotationProvider: Syrus::Plugin::DiffReviewAnnotationProvider,
      JobVisibilityRestriction: Syrus::Plugin::JobVisibilityRestriction,
      McpRunContextContributor: Syrus::Plugin::McpRunContextContributor,
      PostImplementationReviewProvider: Syrus::Plugin::PostImplementationReviewProvider,
      RepositoryConfiguration: Syrus::Plugin::RepositoryConfiguration,
      RepositoryFilter: Syrus::Plugin::RepositoryFilter, RetentionPolicy: Syrus::Plugin::RetentionPolicy,
      ReviewContextContributor: Syrus::Plugin::ReviewContextContributor, ReviewGate: Syrus::Plugin::ReviewGate,
      ReviewPresentationContributor: Syrus::Plugin::ReviewPresentationContributor,
      ReviewerTargetProvider: Syrus::Plugin::ReviewerTargetProvider
    }.each do |name, core|
      expect(Syrus::Host.const_get(name)).to equal(core), name.to_s
      expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true), name.to_s
    end
  end

  it "aliases the content, path, role, reviewer-target, gate and handle facades onto their core values" do
    {
      ContentReader: RepositoryContent, PathJail: Syrus::PathJail, PathJailEscape: Syrus::PathJail::PathEscape,
      SyrusYmlParseError: SyrusYml::ParseError, AgentRole: AgentRole, ReviewerTargetResolver: ReviewerTargets,
      ReviewerTargetRequired: ReviewerTargets::TargetRequired,
      ReviewerTargetUnavailable: ReviewerTargets::TargetUnavailable, GateResult: WorkUnits::GateResult,
      HandleRegistry: HandleRegistry, WorkLauncher: WorkUnits::Launcher,
      WorkLaunchConflict: WorkUnits::Launcher::LockConflict, Record: ApplicationRecord
    }.each do |name, core|
      expect(Syrus::Host.const_get(name)).to equal(core), name.to_s
      expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true), name.to_s
    end
  end

  it "backs every listed member of the callable facades with the core singleton" do
    {
      ContentReader: RepositoryContent, PathJail: Syrus::PathJail, ReviewerTargetResolver: ReviewerTargets,
      GateResult: WorkUnits::GateResult, HandleRegistry: HandleRegistry, UiSlot: Syrus::Plugin::UiSlot,
      GitRunner: GitRunner, McpTools: Mcp::Tools, ToolContext: McpToolContext,
      WorkLauncher: WorkUnits::Launcher, Record: ApplicationRecord
    }.each do |name, target|
      api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::#{name}" }
      callable = { ContentReader: %w[for], PathJail: %w[resolve!], ReviewerTargetResolver: %w[resolve],
                   GateResult: %w[pass block], HandleRegistry: %w[normalize claim! rename! release!],
                   UiSlot: %w[valid_slot?], GitRunner: %w[redact], McpTools: %w[not_authorized],
                   ToolContext: %w[from_run], WorkLauncher: %w[instantiate start! create_and_start!],
                   Record: %w[connection sanitize_sql_like] }.fetch(name)
      expect(api.members).to include(*callable), name.to_s
      callable.each { |member| expect(target).to respond_to(member), "#{name}.#{member}" }
    end
    expect(Syrus::Host::WorkflowWorkspace::REQUIRED_BRANCH_ARTIFACT).to eq(WorkflowWorkspace::REQUIRED_BRANCH_ARTIFACT)
    expect(Syrus::Host::UiSlot::SLOTS).to equal(Syrus::Plugin::UiSlot::SLOTS)
    expect(Syrus::Host::ReviewGate::SLOTS).to equal(Syrus::Plugin::ReviewGate::SLOTS)
  end

  it "exposes the agent role identifiers the plugins pass as tool-context roles" do
    api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::AgentRole" }

    expect(api.members).to include("COWORKER", "COWORKER_CHAT", "WORKFLOW_COWORKER_REVIEWER", "WORKFLOW_ROLES")
    api.members.each { |role| expect(Syrus::Host::AgentRole.const_get(role)).to equal(AgentRole.const_get(role)) }
  end

  it "keeps the gate result and reviewer-target error contracts working through the facades" do
    expect(Syrus::Host::GateResult.pass).to be_pass
    expect(Syrus::Host::GateResult.block(reason: "busy")).to be_blocked
    expect(Syrus::Host::ReviewerTargetRequired.ancestors).to include(StandardError)
    expect { raise Syrus::Host::PathJailEscape.new(reason: :escape, relative_path: "../x", root: "/r") }
      .to raise_error(Syrus::PathJail::PathEscape)
  end

  it "queues chat title generation without exposing the job to plugins" do
    expect {
      Syrus::Host::ChatTitles.enqueue(chat_id: 12, message_id: 34)
    }.to have_enqueued_job(ChatTitleJob).with(12, 34)
  end

  it "reads disk usage without exposing the core service" do
    snapshot = instance_double(DataRootDiskUsage::Snapshot)
    allow(DataRootDiskUsage).to receive(:read).with("/srv/backups").and_return(snapshot)

    expect(Syrus::Host::DiskUsage.read("/srv/backups")).to equal(snapshot)
  end

  it "builds system alerts without exposing the core value class" do
    alert = Syrus::Host::SystemAlert.build(
      id: "plugin:warning", severity: :warn, title: "Warning", message: "Details", action_steps: [ "Inspect it." ]
    )

    expect(alert).to be_a(SystemAlerts::Alert)
    expect(alert.id).to eq("plugin:warning")
  end

  it "requires admin page providers to implement their declared metadata" do
    provider = Class.new { include Syrus::Host::AdminPage }

    expect { provider.admin_pages }.to raise_error(NotImplementedError, /implement \.admin_pages/)
  end

  it "resolves alias targets again instead of retaining an earlier class generation" do
    original = ApplicationRecord
    replacement = Class.new
    Object.send(:remove_const, :ApplicationRecord)
    Object.const_set(:ApplicationRecord, replacement)

    described_class.install!

    expect(Syrus::Host::Record).to equal(replacement)
  ensure
    Object.send(:remove_const, :ApplicationRecord)
    Object.const_set(:ApplicationRecord, original)
  end

  it "does not discard contracts managed by another host API declaration" do
    external = Syrus::Host.api(
      "Syrus::Host::ExternalExample",
      since: "1.2.3",
      summary: "An independently managed contract.",
      members: []
    )

    described_class.install!

    expect(Syrus::Host.apis).to include(external)
  end

  it "keeps each reloadable domain facade in its Zeitwerk-matching file" do
    described_class::DOMAIN_CONTRACTS.each_key do |name|
      path = Rails.root.join("app/models/syrus/host/#{name.to_s.underscore}.rb")

      expect(path).to exist
      expect("Syrus::Host::#{name}".constantize.record_class).to equal(name.to_s.constantize)
    end
  end

  it "aliases the product plugin-point facades onto their core modules and declares their contracts" do
    {
      ChatJobStatusExtension: Syrus::Plugin::ChatJobStatusExtension, ChatMediaSource: Syrus::Plugin::ChatMediaSource,
      ChatPromptInjector: Syrus::Plugin::ChatPromptInjector, DomainSubscriber: Syrus::Plugin::DomainSubscriber,
      GraderFailureSummarizer: Syrus::Plugin::GraderFailureSummarizer, JobOrigin: Syrus::Plugin::JobOrigin,
      PreviewPanelRetention: Syrus::Plugin::PreviewPanelRetention, RepoPageTab: Syrus::Plugin::RepoPageTab,
      RepositoryRecommendation: Syrus::Plugin::RepositoryRecommendation,
      RuntimeSessionProvider: Syrus::Plugin::RuntimeSessionProvider, TestEvidence: Syrus::Plugin::TestEvidence,
      WorkspaceTab: Syrus::Plugin::WorkspaceTab
    }.each do |name, core|
      expect(Syrus::Host.const_get(name)).to equal(core), name.to_s
      api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::#{name}" }
      expect(api).to be_present, name.to_s
      expect(api.members).not_to be_empty, name.to_s
      expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true), name.to_s
    end
  end

  it "lists only members the product plugin-point modules define" do
    %i[ChatJobStatusExtension ChatMediaSource ChatPromptInjector DomainSubscriber GraderFailureSummarizer JobOrigin
       PreviewPanelRetention RepoPageTab RepositoryRecommendation RuntimeSessionProvider TestEvidence
       WorkspaceTab].each do |name|
      core = Syrus::Host.const_get(name)
      api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::#{name}" }
      api.members.each do |member|
        # Hook modules may only document a member implementers supply, so
        # accept a defined method or a mention in the module's own source.
        source = File.read(Syrus::Plugin.const_source_location(name.to_s).first)
        defined_by = core.instance_methods.include?(member.to_sym) || core.respond_to?(member) ||
                     source.include?(member.delete_suffix("?").delete_suffix("!"))
        expect(defined_by).to be(true), "#{name}##{member}"
      end
    end
  end
end
