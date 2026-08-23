require "rails_helper"

RSpec.describe LandingValidationPrefetcher do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }
  let(:source_job) { approved_job(issue_number: 1, approved_at: 2.minutes.ago, state: "landing") }
  let(:candidate) { approved_job(issue_number: 2, approved_at: 1.minute.ago) }
  let(:git) { instance_double(GitRunner) }
  let(:source_path) { Pathname.new(Dir.mktmpdir("landing-validation-source")) }
  let(:workflow) do
    Workflows::AutoMerge.instantiate(job: source_job).tap do |wf|
      wf.update!(state: "running")
    end
  end

  def approved_job(issue_number:, approved_at:, state: "approved")
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: issue_number,
      pr_number: issue_number,
      branch_name: "syrus/issue-#{issue_number}",
      state: state,
      approved_at: approved_at
    )
  end

  def pr(head_sha, base_ref)
    double("pr", head: double(sha: head_sha), base: double(sha: "base-sha", ref: base_ref))
  end

  def active_work_unit_for(job, kind:, state: "running", workflow: nil)
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      actor: job.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: state,
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      workflow: workflow
    )
    unit.work_unit_members.create!(job: job, role: "primary")
    unit
  end

  before do
    Feature.find_or_create_by!(slug: "landing_validation_prefetch") do |feature|
      feature.category = "Operations"
      feature.name = "Landing validation prefetch"
      feature.enabled = false
    end.update!(enabled: false)
    Feature.clear_enabled_cache!("landing_validation_prefetch")
    candidate
    allow(WorkflowWorkspace).to receive(:path_for).and_call_original
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(source_path)
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: source_path.to_s).and_return("source-head\n")
    allow(git).to receive(:run).with("rev-parse", "HEAD^{tree}", chdir: source_path.to_s).and_return("source-tree\n")
    allow(GithubClient).to receive(:for).and_return(double("GithubClient", pull_request: pr("candidate-head", "main")))
    allow(WorkUnits::Launcher).to receive(:start!)
  end

  after do
    FileUtils.rm_rf(source_path.to_s)
  end

  it "does not dispatch while the feature is disabled" do
    expect {
      described_class.after_landing_graders_passed(workflow: workflow)
    }.not_to change { Workflow.where(trigger_kind: "landing_validation").count }
  end

  it "dispatches a landing_validation workflow for the next eligible job when enabled" do
    Feature.find_by!(slug: "landing_validation_prefetch").update!(enabled: true)

    expect {
      described_class.after_landing_graders_passed(workflow: workflow)
    }.to change { Workflow.where(trigger_kind: "landing_validation", job: candidate).count }.by(1)

    prefetch = Workflow.where(trigger_kind: "landing_validation", job: candidate).last
    expect(prefetch.artifacts).to include(
      "prefetch_source_workflow_id" => workflow.id,
      "prefetch_source_job_id" => source_job.id,
      "prefetch_source_head_sha" => "source-head",
      "prefetch_source_tree_sha" => "source-tree",
      "predicted_base_sha" => "source-head",
      "predicted_base_tree_sha" => "source-tree",
      "prefetch_candidate_head_sha" => "candidate-head"
    )
    expect(prefetch.work_unit).to be_present
    expect(WorkUnits::Launcher).to have_received(:start!).with(prefetch)
  end

  it "does not dispatch ordinary validation when the candidate has active validation WorkUnit ownership" do
    Feature.find_by!(slug: "landing_validation_prefetch").update!(enabled: true)
    active_work_unit_for(candidate, kind: "landing_validation")

    expect {
      described_class.after_landing_graders_passed(workflow: workflow)
    }.not_to change { Workflow.where(trigger_kind: "landing_validation", job: candidate).count }

    expect(WorkUnits::Launcher).not_to have_received(:start!)
  end

  it "dispatches a merge_train_validation workflow for the next eligible Epic landing unit" do
    Feature.find_by!(slug: "landing_validation_prefetch").update!(enabled: true)
    AppSetting.current.update!(merge_train_enabled: true)
    candidate.destroy!

    epic = Factories.epic(user: user, repository: repository, state: "ready")
    first = approved_job(issue_number: 10, approved_at: 1.minute.ago).tap do |job|
      job.update!(epic: epic, branch_name: "syrus/issue-10-#{job.id}")
    end
    second = approved_job(issue_number: 11, approved_at: 30.seconds.ago).tap do |job|
      job.update!(epic: epic, branch_name: "syrus/issue-11-#{job.id}", parent_job: first)
    end

    expect {
      described_class.after_landing_graders_passed(workflow: workflow)
    }.to change { Workflow.where(trigger_kind: "merge_train_validation", job: second).count }.by(1)

    prefetch = Workflow.where(trigger_kind: "merge_train_validation", job: second).last
    expect(prefetch.artifacts).to include(
      "prefetch_landing_unit_key" => "epic:#{epic.id}",
      "prefetch_landing_unit_kind" => "merge_train",
      "prefetch_merge_train_epic_id" => epic.id,
      "prefetch_merge_train_member_job_ids" => [ first.id, second.id ],
      "prefetch_source_head_sha" => "source-head",
      "predicted_base_sha" => "source-head",
      "predicted_base_tree_sha" => "source-tree",
      "predicted_base_ref" => repository.default_branch
    )
    expect(prefetch.work_unit).to be_present
    expect(WorkUnits::Launcher).to have_received(:start!).with(prefetch)
  end

  it "does not dispatch merge-train validation when a member has active validation WorkUnit ownership" do
    Feature.find_by!(slug: "landing_validation_prefetch").update!(enabled: true)
    AppSetting.current.update!(merge_train_enabled: true)
    candidate.destroy!

    epic = Factories.epic(user: user, repository: repository, state: "ready")
    first = approved_job(issue_number: 10, approved_at: 1.minute.ago).tap do |job|
      job.update!(epic: epic, branch_name: "syrus/issue-10-#{job.id}")
    end
    second = approved_job(issue_number: 11, approved_at: 30.seconds.ago).tap do |job|
      job.update!(epic: epic, branch_name: "syrus/issue-11-#{job.id}", parent_job: first)
    end
    active_work_unit_for(first, kind: "merge_train_validation")

    expect {
      described_class.after_landing_graders_passed(workflow: workflow)
    }.not_to change { Workflow.where(trigger_kind: "merge_train_validation", job: second).count }

    expect(WorkUnits::Launcher).not_to have_received(:start!)
  end

  it "lets a successful merge_train workflow prefetch the next ordinary landing unit" do
    Feature.find_by!(slug: "landing_validation_prefetch").update!(enabled: true)
    AppSetting.current.update!(merge_train_enabled: true)

    epic = Factories.epic(user: user, repository: repository, state: "ready")
    source_job.update!(epic: epic, branch_name: "syrus/issue-1-#{source_job.id}")
    workflow.update!(trigger_kind: "merge_train")
    candidate.update!(approved_at: 30.seconds.ago)

    expect {
      described_class.after_landing_graders_passed(workflow: workflow)
    }.to change { Workflow.where(trigger_kind: "landing_validation", job: candidate).count }.by(1)
  end

  it "dispatches a merge_train_validation workflow for the next eligible epicless job-bundle landing unit" do
    Feature.find_by!(slug: "landing_validation_prefetch").update!(enabled: true)
    Feature.find_or_create_by!(slug: "epicless_job_bundling") do |feature|
      feature.category = "Labs"
      feature.name = "Epicless Job bundling"
    end.update!(enabled: true)
    candidate.destroy!

    first = approved_job(issue_number: 10, approved_at: 1.minute.ago)
    second = approved_job(issue_number: 11, approved_at: 30.seconds.ago)

    expect {
      described_class.after_landing_graders_passed(workflow: workflow)
    }.to change { Workflow.where(trigger_kind: "merge_train_validation", job: second).count }.by(1)

    prefetch = Workflow.where(trigger_kind: "merge_train_validation", job: second).last
    expect(prefetch.artifacts).to include(
      "prefetch_landing_unit_kind" => "merge_train",
      "prefetch_job_bundle_priority" => "medium",
      "prefetch_source_head_sha" => "source-head",
      "predicted_base_sha" => "source-head",
      "predicted_base_tree_sha" => "source-tree",
      "predicted_base_ref" => repository.default_branch
    )
    expect(prefetch.artifacts["prefetch_merge_train_member_job_ids"]).to match_array([ first.id, second.id ])
    expect(prefetch.work_unit).to be_present
    expect(WorkUnits::Launcher).to have_received(:start!).with(prefetch)
  end

  it "lets a successful epicless job-bundle merge_train workflow prefetch the next ordinary landing unit" do
    Feature.find_by!(slug: "landing_validation_prefetch").update!(enabled: true)
    Feature.find_or_create_by!(slug: "epicless_job_bundling") do |feature|
      feature.category = "Labs"
      feature.name = "Epicless Job bundling"
    end.update!(enabled: true)

    other_member = approved_job(issue_number: 20, approved_at: 3.minutes.ago, state: "landing")
    train = MergeTrain.create!(repository: repository, base_branch: repository.default_branch, priority: "medium")
    MergeTrainMember.create!(merge_train: train, job: other_member, position: 0)
    MergeTrainMember.create!(merge_train: train, job: source_job, position: 1)
    workflow.update!(trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id })
    candidate.update!(approved_at: 30.seconds.ago)

    expect {
      described_class.after_landing_graders_passed(workflow: workflow)
    }.to change { Workflow.where(trigger_kind: "landing_validation", job: candidate).count }.by(1)
  end
end
