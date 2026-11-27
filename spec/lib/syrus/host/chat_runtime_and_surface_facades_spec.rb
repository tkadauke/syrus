require "rails_helper"

RSpec.describe "Syrus::Host chat, runtime, preview and appearance facades" do
  FACADES = {
    ChatProvider: Syrus::Plugin::ChatProvider, CableChannel: ApplicationCable::Channel,
    PlatformPollingJob: PlatformPollingJob, InboundMessageRouter: InboundMessageRouter,
    BugReportRouter: BugReports::Router, TypedArtifactRenderer: TypedArtifactRenderer,
    ColorPalette: Appearance::ColorPalette, ThemeRecord: Theme, UiEngagementSampleRecord: UiEngagementSample,
    ChatProposalRecord: ChatProposal, ChatSpendEntryRecord: ChatSpendEntry, ChatWakeupRecord: ChatWakeup,
    ChatAttachmentRecord: ChatAttachment, ChatAssociatedJobs: ChatAssociatedJobs, ChatLockErrors: ChatLockErrors,
    ChatWorkEvents: ChatWorkEvents, ChatResultBadges: ChatResultBadges, ChatMediaLibrary: ChatMediaLibrary,
    ChatHistoryTranscriptRenderer: ChatHistoryTranscriptRenderer, ChatContextCompactor: ChatContextCompactor,
    ChatSessionRehydrator: ChatSessionRehydrator, ChatWorkspace: ChatWorkspace,
    PreviewPanelRecord: PreviewPanel, PreviewPanelVersionRecord: PreviewPanelVersion,
    PreviewCommandSource: PreviewCommandSource, PreviewProcessLauncher: PreviewProcessLauncher,
    RuntimeSessionRecord: RuntimeSession, RuntimeControlLease: RuntimeControlLease,
    RuntimeSessionRegistry: RuntimeSessionProviders
  }.freeze

  it "aliases each facade onto its core value" do
    FACADES.each { |name, core| expect(Syrus::Host.const_get(name)).to equal(core), name.to_s }
  end

  it "declares a public contract for each facade" do
    FACADES.each_key { |name| expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true), name.to_s }
  end

  it "only lists members the core value really responds to" do
    FACADES.each do |name, core|
      api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::#{name}" }
      api.members.each do |member|
        ok = member.match?(/\A[A-Z]/) ? core.const_defined?(member) : (core.respond_to?(member) || core.method_defined?(member) || core.private_method_defined?(member))
        expect(ok).to be(true), "#{name} lists #{member}"
      end
    end
  end

  it "exposes the chat modes through the chat session facade" do
    expect(Syrus::Host::ChatSession::MODES).to equal(::ChatSession::MODES)
    expect(Syrus::Host.apis.find { |api| api.name == "Syrus::Host::ChatSession" }.members).to include("MODES")
  end

  it "publishes the chat persistence and lifecycle facades" do
    %w[ChatSessionRecord ChatMessageRecord ChatPendingActionRecord ChatTurnJob MentionableResolver].each do |name|
      expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true)
    end
  end
end
