require "rails_helper"

RSpec.describe "Syrus::Host work-engine record facades" do
  ALIASED = {
    PolicyBase: ApplicationPolicy, Handle: Handle, InputSourceBase: InputSource, GitMergeDrivers: GitMergeDrivers,
    DiffReviewComment: DiffReviewComment, DiffReviewVersion: DiffReviewVersion, GithubClient: GithubClient,
    GithubAuthenticatedGit: GithubAuthenticatedGit, GithubApiUsageRollup: GithubApiUsageRollup,
    GithubIssueJobAttributes: GithubIssueJobAttributes, GithubIngestPolicy: IngestPolicy,
    GithubIssueImageExtractor: IssueImageExtractor, GithubIssueImageIngestJob: IngestIssueImagesJob,
    GithubIssueClassifierJob: ClassifyIssueJob, FinalReviewVersion: DiffReviewVersions::FinalReviewVersion,
    PendingWorkWakeup: InputSources::PendingWorkWakeup, RepositoryRecord: Repository, UserRecord: User,
    TeamRecord: Team, TeamMembershipRecord: TeamMembership, TeamRepositoryRecord: TeamRepository,
    RepositoryMembershipRecord: RepositoryMembership, RepositoryPolicy: RepositoryPolicy,
    RepositoryBareClone: RepositoryBareClone, RepositorySummarySerialization: RepositorySummarySerialization,
    RepoDefaultBranchSyrusYml: RepoDefaultBranchSyrusYml, RepoDeploymentStagesReader: RepoDeploymentStagesReader,
    SyrusYmlConfig: SyrusYml, PrReviewComment: PrReviewComment, Document: Document,
    ReviewVerdictSubmission: ReviewEvidence::VerdictSubmission,
    Epic: Epic, Step: Step, StepHandlerBase: Steps::Base, AdversarialReviewStep: Steps::AdversarialReview,
    MergeTrainLandStep: Steps::MergeTrainLand, WorkflowBase: Workflows::Base, WorkDefinitionBase: WorkDefinitions::Base,
    RunJob: RunJob, RunDiff: RunDiff, RunHeartbeat: RunHeartbeat, WorkflowActivityEvent: WorkflowActivityEvent,
    WorkflowVisualEvidence: WorkflowVisualEvidence, WorkflowWarnings: WorkflowWarnings, StepWorkspace: StepWorkspace,
    StateTransition: StateTransition, JobApproval: JobApproval, JobLog: JobLog, JobPin: JobPin, MergeTrain: MergeTrain,
    MergeTrainDispatcher: MergeTrainDispatcher, MergeTrainMember: MergeTrainMember, LandedCommit: LandedCommit,
    LandingFailureHandler: LandingFailureHandler, RepairIneligible: RepairEligibility::Ineligible,
    SpawnedProcess: SpawnedProcess, JobDefinitionUpdater: JobDefinitionUpdater, AutoApproveModes: AutoApproveModes,
    EpicMarkerParser: EpicMarkerParser, DirectJobCreator: DirectJobs::Creator,
    InvestigationJobCreator: InvestigationJobs::Creator, JobFilter: Jobs::Filter, EpicFilter: Epics::Filter,
    TestCaseIdentity: TestCaseIdentity, JunitXmlParser: JunitXmlParser, JobRecord: Job, RunRecord: Run, WorkflowRecord: Workflow
  }.freeze

  ALIASED.each do |name, core|
    it "aliases Syrus::Host::#{name} to its core value and declares a public contract" do
      expect(Syrus::Host.const_get(name)).to equal(core)
      expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true)
    end

    it "only lists members that exist on Syrus::Host::#{name}" do
      api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::#{name}" }
      expect(api.members).not_to be_empty
      api.members.each do |member|
        if member.match?(/\A[A-Z]/)
          expect(core.const_defined?(member)).to be(true), member
        else
          instance = core.respond_to?(:column_names) ? core.column_names.include?(member) || core.method_defined?(member) || core.reflect_on_association(member.to_sym) : core.method_defined?(member)
          expect(core.respond_to?(member) || instance).to be_truthy, "#{name}.#{member}"
        end
      end
    end
  end
end
