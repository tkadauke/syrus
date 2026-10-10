class MergeTrainFixReplay
  SOURCE_TRAIN_ARTIFACT = "merge_train_keep_fixes_source_train_id".freeze
  STATUS_ARTIFACT = "merge_train_keep_fixes_status".freeze

  Result = Data.define(:status, :commits, :reason) do
    def replayed? = status == "replayed"
    def skipped? = status == "skipped"
    def conflicted? = status == "conflicted"
  end

  def self.source_artifacts_for(train)
    return {} unless eligible_source?(train)

    { SOURCE_TRAIN_ARTIFACT => train.id }
  end

  def self.eligible_source?(train)
    return false unless AppSetting.merge_train_keeps_fixes_on_failure?
    return false unless train
    return false if train.integration_branch.blank? || train.integration_sha.blank?

    latest_workflow = workflow_for(train)
    return true if stale_base_rebuild_required?(latest_workflow)

    failed_run_for(latest_workflow)&.run_failure_classification&.retryable == true
  end

  def self.workflow_for(train)
    Workflow.where(trigger_kind: "merge_train").order(id: :desc).detect do |workflow|
      workflow.artifact("merge_train_id").to_i == train.id
    end
  end

  def self.failed_run_for(workflow)
    return unless workflow

    Run.joins(:step)
       .where(steps: { workflow_id: workflow.id })
       .where(state: "failed")
       .order(id: :desc)
       .includes(:run_failure_classification)
       .first
  end

  def self.stale_base_rebuild_required?(workflow)
    return false unless workflow

    stale = workflow.artifact(Steps::MergeTrainLand::STALE_BASE_ARTIFACT)
    return true if stale.is_a?(Hash) && stale["reason"].in?(%w[base_moved missing_built_base_sha])

    LandingFailureHandler.merge_train_rebuild_required?(workflow.failure_reason)
  end

  def initialize(workflow:, train:, git:, chdir:, fetch_branch:, log:)
    @workflow = workflow
    @train = train
    @git = git
    @chdir = chdir
    @fetch_branch = fetch_branch
    @log = log
  end

  def call
    source_train = source_train_for_workflow
    return skip!("no source train artifact") unless source_train
    return skip!("source train is not eligible") unless self.class.eligible_source?(source_train)
    return skip!("member set changed") unless same_members?(source_train)

    repair_commits = repair_commits_for(source_train)
    return skip!("no repair commits found") if repair_commits.empty?

    replay!(source_train, repair_commits)
  rescue GitRunner::GitError => e
    skip!("source repair history unavailable: #{e.message.to_s.lines.first.to_s.strip}")
  end

  private

  def source_train_for_workflow
    id = @workflow.artifact(SOURCE_TRAIN_ARTIFACT).to_i
    return if id <= 0

    MergeTrain.find_by(id: id)
  end

  def same_members?(source_train)
    member_ids(source_train) == member_ids(@train)
  end

  def member_ids(train)
    train.members.order(:position).pluck(:job_id)
  end

  def repair_commits_for(source_train)
    source_workflow = self.class.workflow_for(source_train)
    source_base = source_workflow&.artifact(Steps::MergeTrainLand::BASE_SHA_ARTIFACT).to_s.presence
    return [] if source_base.blank?

    @fetch_branch.call(source_train.integration_branch)
    all_commits = @git.run("rev-list", "--reverse", "#{source_base}..#{source_train.integration_sha}", chdir: @chdir)
      .to_s.split("\n").map(&:strip).reject(&:empty?)
    member_commits = LandedCommit
      .where(landable: Job.where(id: source_train.members.select(:job_id)), kind: "implementation")
      .pluck(:sha)
      .to_set

    all_commits.reject { |sha| member_commits.include?(sha) }
  end

  def replay!(source_train, repair_commits)
    pre_replay_sha = @git.run("rev-parse", "HEAD", chdir: @chdir).strip
    repair_commits.each do |sha|
      @git.run("cherry-pick", sha, chdir: @chdir)
    rescue GitRunner::GitError => e
      abort_cherry_pick
      @git.run("reset", "--hard", pre_replay_sha, chdir: @chdir)
      return conflict!("repair commit #{sha} from merge train #{source_train.id} conflicted: #{e.message}")
    end

    @workflow.set_artifact!(STATUS_ARTIFACT, { "status" => "replayed", "source_train_id" => source_train.id, "commit_shas" => repair_commits })
    @log.call("merge_train: replayed #{repair_commits.size} repair commit(s) from previous train #{source_train.id}", kind: "system")
    Result.new(status: "replayed", commits: repair_commits, reason: nil)
  end

  def abort_cherry_pick
    @git.run("cherry-pick", "--abort", chdir: @chdir)
  rescue GitRunner::GitError
    nil
  end

  def skip!(reason)
    @workflow.set_artifact!(STATUS_ARTIFACT, { "status" => "skipped", "reason" => reason })
    @log.call("merge_train: skipped previous repair replay (#{reason})", kind: "system")
    Result.new(status: "skipped", commits: [], reason: reason)
  end

  def conflict!(reason)
    @workflow.set_artifact!(STATUS_ARTIFACT, { "status" => "conflicted", "reason" => reason })
    @log.call("merge_train: previous repair replay conflicted; continuing with rebuilt member assembly only (#{reason})", kind: "system")
    Result.new(status: "conflicted", commits: [], reason: reason)
  end
end
