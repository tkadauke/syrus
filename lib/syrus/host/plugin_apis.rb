require "syrus/host"

module Syrus
  module Host
    module PluginApis
      # These are the established plugin-authoring contracts that predate
      # Syrus::Host. New public APIs belong under Syrus::Host instead.
      INTERFACES = %w[
        Adjudicator AdminPage AffectedTestAnalyzer AgentProvider ApprovalProvider
        ArtifactRenderer AutofixCommand BuildSystemGraphProvider Callbacks
        ChatIdentityProvider ChatJobStatusExtension ChatMcpToolSet ChatMediaSource
        ChatPayloadContributor ChatPromptInjector ChatProvider ChatTurnFinalizer
        ChatTurnLifecycle ChatTurnOrientation ChatWorkspaceLifecycle CiLogParser
        CoverageAnalyzer DependencyAuditCommand DiffReviewAnnotationProvider
        DiffReviewFilePatternProvider DomainSubscriber ExecutionBackend
        FocusedTestCommand GradeDetector GraderAugmentor GraderFailureSummarizer
        GraderInputMaterializer GraderType InputSource JobOrigin
        JobVisibilityRestriction McpRunContextContributor McpToolSet MemoryStore
        Mentionable PermissionProvider PlatformDelivery
        PostImplementationReviewProvider PrepareDetector PreviewPanelRetention
        PreviewPanelViewer PreviewProvider ProblemProvider PromptInjector
        PurgeContributor RepoPageTab RepositoryConfiguration
        RepositoryContentProvider RepositoryFilter RepositoryRecommendation
        RetentionPolicy ReviewContextContributor ReviewCriteriaProvider ReviewGate
        ReviewPresentationContributor ReviewerTargetProvider RuntimeSessionProvider
        SidebarPage SlugType SourceControlProvider SpeechToTextProvider
        StepEnvironment TestEvidence UiSlot WorkerCapabilityProbe
        WorkflowArtifactContributor WorkflowKinds WorkspaceGitTransport WorkspaceTab
      ].freeze
    end
  end
end

Syrus::Host.api(
  "Syrus::PluginApi",
  since: "0.1.16",
  summary: "Declares a plugin manifest and its contributions.",
  members: %w[syrus_plugin syrus_plugin_definition register! enabled?]
)

Syrus::Host::PluginApis::INTERFACES.each do |interface|
  Syrus::Host.api(
    "Syrus::Plugin::#{interface}",
    since: "0.1.16",
    summary: "Defines the #{interface} plugin extension-point contract.",
    members: []
  )
end
