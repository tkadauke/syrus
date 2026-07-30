require "rails_helper"

RSpec.describe Epic do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
      RepoReconciliationPlan::Result.new(mode: "none", source: "none", note: "stubbed")
    )
  end

  describe "search indexing" do
    it "enqueues indexing when created" do
      repository = Factories.repository

      expect {
        Factories.epic(user: repository.user, repository: repository, title: "Search me")
      }.to have_enqueued_job(IndexEpicSearchJob).with(kind_of(Integer)).on_queue("default")
    end

    it "enqueues indexing when updated" do
      epic = Factories.epic(title: "Search me")
      clear_enqueued_jobs

      expect {
        epic.update!(title: "Search me again")
      }.to have_enqueued_job(IndexEpicSearchJob).with(epic.id).on_queue("default")
    end
  end

  describe "app events" do
    it "broadcasts a compact event when created" do
      repository = Factories.repository

      expect(AppUserChannel).to receive(:broadcast_to).with(
        repository.user,
        hash_including(
          "type" => "epic.updated",
          "resource" => "epic",
          "id" => kind_of(Integer),
          "changed" => include("epic.created", "title", "repository_id")
        )
      )

      described_class.create!(user: repository.user, repository: repository, title: "Raise the forum")
    end

    it "broadcasts changed dashboard-relevant fields when updated" do
      allow(AppUserChannel).to receive(:broadcast_to)
      epic = Factories.epic(title: "Raise the forum")

      expect(AppUserChannel).to receive(:broadcast_to).with(
        epic.user,
        hash_including(
          "type" => "epic.updated",
          "resource" => "epic",
          "id" => epic.id,
          "changed" => include("epic.updated", "state", "title")
        )
      )

      epic.update!(state: "ready", title: "Raise the basilica")
    end
  end

  it "defaults auto-approval to never and accepts grader-gated modes" do
    epic = Factories.epic
    expect(epic.auto_approve_mode).to eq("never")

    epic.update!(auto_approve_mode: "if_graders_pass")
    expect(epic.auto_approve_mode).to eq("if_graders_pass")
  end

  it "defaults dependency policy to linear even when the repository default is nonlinear" do
    repository = Factories.repository(epic_dependency_policy: "nonlinear")
    epic = Factories.epic(user: repository.user, repository: repository)

    expect(epic.epic_dependency_policy).to eq("linear")
    expect(epic.resolved_epic_dependency_policy).to eq("linear")
  end

  it "allows an Epic to override the repository dependency policy" do
    repository = Factories.repository(epic_dependency_policy: "linear")
    epic = Factories.epic(user: repository.user, repository: repository, epic_dependency_policy: "nonlinear")

    expect(epic.resolved_epic_dependency_policy).to eq("nonlinear")

    epic.update!(epic_dependency_policy: "linear")
    expect(epic.resolved_epic_dependency_policy).to eq("linear")
  end

  it "rejects unknown Epic dependency policy overrides" do
    epic = Factories.epic
    epic.epic_dependency_policy = "braided"

    expect(epic).not_to be_valid
    expect(epic.errors[:epic_dependency_policy]).to be_present
  end

  it "rejects the retired inherited Epic dependency policy" do
    epic = Factories.epic
    epic.epic_dependency_policy = "inherit"

    expect(epic).not_to be_valid
    expect(epic.errors[:epic_dependency_policy]).to be_present
  end

  it "keeps child Job epic titles in sync when renamed" do
    epic = Factories.epic(title: "Migration train")
    job = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic)

    epic.update!(title: "Landing train")

    expect(job.reload.epic_title).to eq("Landing train")
  end

  it "records title and description versions with the current actor" do
    actor = Factories.user(email_address: "actor@example.com")
    epic = Factories.epic(title: "Migration train", description: "Old notes")

    Current.api_user = actor

    expect {
      epic.update!(title: "Landing train", description: "New notes")
    }.to change(EpicVersion, :count).by(1)

    version = epic.versions.last
    expect(version.user).to eq(actor)
    expect(version.title_before).to eq("Migration train")
    expect(version.title_after).to eq("Landing train")
    expect(version.description_before).to eq("Old notes")
    expect(version.description_after).to eq("New notes")
  ensure
    Current.reset
  end

  it "records system versions when no current actor is present" do
    epic = Factories.epic(title: "Migration train")

    expect {
      epic.update!(description: "System note")
    }.to change(EpicVersion, :count).by(1)

    version = epic.versions.last
    expect(version.user).to be_nil
    expect(version.title_before).to be_nil
    expect(version.title_after).to be_nil
    expect(version.description_before).to be_nil
    expect(version.description_after).to eq("System note")
  end

  it "does not record a version for unrelated updates" do
    epic = Factories.epic(title: "Migration train", state: "ready")

    expect {
      epic.update!(claimed_at: Time.current)
    }.not_to change(EpicVersion, :count)
  end

  it "rejects unknown auto-approval modes" do
    epic = Factories.epic
    epic.auto_approve_mode = "always"
    expect(epic).not_to be_valid
    expect(epic.errors[:auto_approve_mode]).to be_present
  end

  describe "#review_ready?" do
    around do |example|
      setting = AppSetting.current
      original_mode = setting.mode
      setting.update!(mode: "simple", mode_configured_at: Time.current)
      example.run
    ensure
      setting&.update!(mode: original_mode || "advanced")
    end

    it "is true only in simple mode when every work Job is merged" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      child_job(epic: epic, number: 10, closure_reason: "pr_merged")
      child_job(epic: epic, number: 11, closure_reason: "external_pr_merged")

      expect(epic.reload).to be_review_ready

      AppSetting.current.update!(mode: "advanced")
      expect(epic.reload).not_to be_review_ready
    end

    it "is false when a child Job finished without merging or the user approved it" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      child_job(epic: epic, number: 10, closure_reason: "no_changes")

      expect(epic.reload).not_to be_review_ready

      epic.jobs.destroy_all
      child_job(epic: epic, number: 11, closure_reason: "pr_merged")
      epic.update!(user_approved_at: Time.current)

      expect(epic.reload).not_to be_review_ready
    end
  end

  describe "#append_review_feedback_job!" do
    around do |example|
      setting = AppSetting.current
      original_mode = setting.mode
      setting.update!(mode: "simple", mode_configured_at: Time.current)
      example.run
    ensure
      setting&.update!(mode: original_mode || "advanced")
    end

    it "creates a new direct Job at the tail of the linear chain and reopens the Epic" do
      epic = Factories.epic(user: user, repository: repository, title: "Checkout polish", state: "in_progress")
      tail = child_job(epic: epic, number: 10, closure_reason: "pr_merged")
      expect(epic.reload).to be_review_ready

      expect {
        @job = epic.append_review_feedback_job!(feedback: "The checkout button is hard to see.", actor: user)
      }.to change(Job, :count).by(1)

      job = @job
      expect(epic.reload).to be_in_progress
      expect(epic.done_at).to be_nil
      expect(job).to have_attributes(
        kind: "direct",
        epic: epic,
        issue_body: "The checkout button is hard to see.",
        auto_merge_enabled: true
      )
      expect(job.dependencies.sole.depends_on_job).to eq(tail)
      expect(epic.reload.auto_approve_mode).to eq("if_graders_pass")
    end
  end

  it "tracks claimed and unclaimed ownership state" do
    owner = Factories.user(email_address: "owner@example.com")
    unclaimed = Factories.epic(user: user, repository: repository, state: "ready")
    claimed = Factories.epic(user: user, repository: repository, state: "ready", owner: owner, claimed_at: 1.hour.ago)

    expect(described_class.unclaimed).to include(unclaimed)
    expect(described_class.claimed).to include(claimed)
    expect(described_class.owned_by(owner)).to include(claimed)
  end

  it "claims, unclaims, and prevents accidental takeover" do
    owner = Factories.user(email_address: "owner@example.com")
    other = Factories.user(email_address: "other@example.com")
    epic = Factories.epic(user: user, repository: repository, state: "ready")

    expect {
      epic.claim!(owner)
    }.to change { epic.reload.owner }.from(nil).to(owner)
      .and change { epic.claimed_at }.from(nil)

    expect {
      epic.claim!(other)
    }.to raise_error(ArgumentError, "Epic is already claimed")

    expect {
      epic.unclaim!(claimant: owner)
    }.to change { epic.reload.owner }.from(owner).to(nil)
      .and change { epic.claimed_at }.to(nil)
  end

  it "does not claim child Jobs to an owner who cannot execute the Epic repository" do
    owner = Factories.user(email_address: "owner@example.com")
    epic = Factories.epic(user: user, repository: repository, state: "ready")
    child = Factories.job_record(user: user, repository: repository, epic: epic, state: "blocked_by_epic")

    epic.claim!(owner)

    expect(child.reload.user).to eq(user)
  end

  it "scopes epics by nullable owner claims" do
    mine = Factories.user
    other = Factories.user
    mine_repo = Factories.repository(user: mine)
    other_repo = Factories.repository(user: other)

    claimed_by_mine = Factories.epic(user: mine, repository: mine_repo, owner_user: mine)
    claimed_by_other = Factories.epic(user: other, repository: other_repo, owner_user: other)
    unclaimed = Factories.epic(user: mine, repository: mine_repo, owner_user: nil)

    expect(described_class.claimed).to include(claimed_by_mine, claimed_by_other)
    expect(described_class.claimed).not_to include(unclaimed)
    expect(described_class.unclaimed).to include(unclaimed)
    expect(described_class.unclaimed).not_to include(claimed_by_mine)
    expect(described_class.owned_by(mine)).to contain_exactly(claimed_by_mine)
    expect(described_class.other_owned_by(mine)).to include(claimed_by_other)
    expect(described_class.other_owned_by(mine)).not_to include(claimed_by_mine, unclaimed)
  end

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def child_job(epic:, number:, closure_reason: nil)
    job = Factories.job_record(user: user, repository: repository, issue_number: number, epic: epic)
    if closure_reason
      job.update!(closure_reason: closure_reason)
      job.close!
    end
    job
  end

  describe "#stuck?" do
    it "is true when in progress with all child Jobs closed but incomplete" do
      epic = described_class.create!(user: user, repository: repository, title: "Stalled train", state: "in_progress")
      child_job(epic: epic, number: 10, closure_reason: "cancelled")

      expect(epic.reload).to be_stuck
    end

    it "is false while open child Jobs remain" do
      epic = described_class.create!(user: user, repository: repository, title: "Active train", state: "in_progress")
      child_job(epic: epic, number: 10, closure_reason: "cancelled")
      child_job(epic: epic, number: 11)

      expect(epic.reload).not_to be_stuck
    end

    it "is false once the Epic is done" do
      epic = described_class.create!(user: user, repository: repository, title: "Completed train", state: "done")
      child_job(epic: epic, number: 10, closure_reason: "cancelled")

      expect(epic.reload).not_to be_stuck
    end

    it "is false for a jobless in-progress Epic (awaiting children, not stalled)" do
      epic = described_class.create!(user: user, repository: repository, title: "Fresh forum", state: "backlog")
      epic.start_implementing!(actor: user)

      expect(epic.reload).to be_in_progress
      expect(epic).not_to be_stuck
    end
  end

  describe "#all_jobs_closed?" do
    it "is true when every child Job is closed" do
      epic = described_class.create!(user: user, repository: repository, title: "Wrapped train", state: "in_progress")
      child_job(epic: epic, number: 10, closure_reason: "cancelled")
      child_job(epic: epic, number: 11, closure_reason: "pr_merged")

      expect(epic.reload).to be_all_jobs_closed
    end

    it "is false with no child Jobs or an open child Job" do
      empty = described_class.create!(user: user, repository: repository, title: "Empty train", state: "in_progress")
      active = described_class.create!(user: user, repository: repository, title: "Active train", state: "in_progress")
      child_job(epic: active, number: 10, closure_reason: "cancelled")
      child_job(epic: active, number: 11)

      expect(empty.reload).not_to be_all_jobs_closed
      expect(active.reload).not_to be_all_jobs_closed
    end
  end

  it "assigns an immutable display number separate from the editable title" do
    epic = described_class.create!(user: user, repository: repository, title: "First pass")

    expect(epic.number).to be_present
    expect(epic.slug).to eq("EPIC-#{epic.number}")

    expect {
      epic.update!(title: "Revised display name")
    }.not_to change(epic, :number)
  end

  it "auto-promotes backlog to ready when dependencies are done and child jobs are confirmed" do
    epic = described_class.create!(user: user, repository: repository, title: "Dependent")

    expect {
      child_job(epic: epic, number: 10)
    }.to change { epic.reload.state }.from("backlog").to("ready")
  end

  it "does not allow empty backlog Epics to move to ready" do
    epic = described_class.create!(user: user, repository: repository, title: "Dependent")

    expect(epic.reload).to be_backlog
    expect(epic.may_auto_ready?).to be false
  end

  it "does not release child Jobs for execution while an upstream Job dependency is unsatisfied" do
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 8, state: "queued")
    epic = described_class.create!(user: user, repository: repository, title: "Dependent", state: "in_progress")
    EpicDependency.create!(epic: epic, depends_on_job: prerequisite)

    expect(epic.reload).not_to be_releases_jobs_for_execution

    prerequisite.update!(closure_reason: "pr_merged")
    prerequisite.close!

    expect(epic.reload).to be_releases_jobs_for_execution
  end

  describe "#all_jobs_approved?" do
    it "is true when every non-closed child Job is approved" do
      epic = described_class.create!(user: user, repository: repository, title: "Landing train")
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1, state: "approved")
      Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        issue_number: 2,
        state: "closed",
        closure_reason: "pr_merged"
      )

      expect(epic.all_jobs_approved?).to be true
    end

    it "is false while any non-closed child Job is not approved" do
      epic = described_class.create!(user: user, repository: repository, title: "Landing train")
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1, state: "approved")
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2, state: "implemented")

      expect(epic.all_jobs_approved?).to be false
    end
  end

  describe "#fully_approved?" do
    it "is true when all work jobs are approved" do
      epic = described_class.create!(user: user, repository: repository, title: "Approvals pending")
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1, state: "approved")
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2, state: "approved")

      expect(epic.fully_approved?).to be true
    end

    it "is true when work jobs are a mix of approved, landing, and closed" do
      epic = described_class.create!(user: user, repository: repository, title: "Mixed approved states")
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1, state: "approved")
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2, state: "landing")
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 3, state: "closed", closure_reason: "pr_merged")

      expect(epic.fully_approved?).to be true
    end

    it "is false when any work job is still pre-approval" do
      epic = described_class.create!(user: user, repository: repository, title: "Not fully approved")
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1, state: "approved")
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2, state: "implemented")

      expect(epic.fully_approved?).to be false
    end

    it "is false when there are no work jobs" do
      epic = described_class.create!(user: user, repository: repository, title: "Empty")

      expect(epic.fully_approved?).to be false
    end
  end

  it "does not auto-promote to ready while an Epic dependency is unfinished" do
    prerequisite = described_class.create!(user: user, repository: repository, title: "Prerequisite")
    epic = described_class.create!(user: user, repository: repository, title: "Dependent")
    EpicDependency.create!(epic: epic, depends_on_epic: prerequisite, derived: false)

    expect(epic.reload).to be_backlog
    expect(epic.may_auto_ready?).to be false
  end

  it "auto-promotes backlog dependents when their Epic dependency becomes done" do
    prerequisite = described_class.create!(user: user, repository: repository, title: "Prerequisite")
    epic = described_class.create!(user: user, repository: repository, title: "Dependent")
    EpicDependency.create!(epic: epic, depends_on_epic: prerequisite, derived: false)
    child_job(epic: epic, number: 10)

    expect(epic.reload).to be_backlog

    expect {
      prerequisite.override_state!("done")
    }.to change { epic.reload.state }.from("backlog").to("ready")
  end

  it "releases blocked child Jobs for in-progress dependents when their Epic dependency becomes done" do
    prerequisite = described_class.create!(user: user, repository: repository, title: "Prerequisite")
    epic = described_class.create!(user: user, repository: repository, title: "Dependent", state: "in_progress")
    EpicDependency.create!(epic: epic, depends_on_epic: prerequisite, derived: false)
    job = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      kind: "direct",
      issue_number: nil,
      issue_title: "Downstream work",
      issue_body: "Do the downstream work",
      state: "blocked_by_epic"
    )

    expect(job.workflows).to be_empty
    expect(epic.reload).not_to be_releases_jobs_for_execution

    expect {
      prerequisite.override_state!("done")
    }.to change { job.reload.state }.from("blocked_by_epic").to("queued")
      .and change { job.workflows.count }.by(1)
      .and change { job.runs.count }.by(1)

    expect(epic.reload).to be_in_progress
    expect(job.workflows.first.trigger_kind).to eq("initial")
  end

  it "releases blocked child Jobs when the dependency Epic becomes fully approved (all jobs approved)" do
    prerequisite = described_class.create!(user: user, repository: repository, title: "Upstream", state: "in_progress")
    epic = described_class.create!(user: user, repository: repository, title: "Downstream", state: "in_progress")
    EpicDependency.create!(epic: epic, depends_on_epic: prerequisite, derived: false)
    upstream_job = Factories.job_record(
      user: user, repository: repository, epic: prerequisite, issue_number: 1, state: "implemented"
    )
    downstream_job = Factories.job_record(
      user: user, repository: repository, epic: epic, kind: "direct",
      issue_number: nil, issue_title: "Downstream work", issue_body: "Do it",
      state: "blocked_by_epic"
    )

    expect(downstream_job.workflows).to be_empty
    expect(epic.reload).not_to be_releases_jobs_for_execution

    expect {
      upstream_job.approve!(via: "operator")
      upstream_job.save!
    }.to change { downstream_job.reload.state }.from("blocked_by_epic").to("queued")
      .and change { downstream_job.workflows.count }.by(1)

    expect(epic.reload).to be_in_progress
  end

  it "does not release child Jobs when starting an Epic with unsatisfied EpicDependency records" do
    blocker = described_class.create!(user: user, repository: repository, title: "Blocker", state: "in_progress")
    epic = described_class.create!(user: user, repository: repository, title: "Gated", state: "in_progress")
    EpicDependency.create!(epic: epic, depends_on_epic: blocker, derived: false)
    job = Factories.job_record(
      user: user, repository: repository, epic: epic, kind: "direct",
      issue_number: nil, issue_title: "Gated work", issue_body: "Do the gated work",
      state: "blocked_by_epic"
    )

    expect(job.workflows).to be_empty

    epic.send(:unblock_child_jobs!)

    expect(job.reload).to be_blocked_by_epic
    expect(job.workflows).to be_empty
  end

  context "with Depends-on refs in description" do
    it "creates an EpicDependency for a same-repository GitHub issue reference" do
      prerequisite = described_class.create!(
        user: user,
        repository: repository,
        title: "Universal dashboard",
        github_issue_url: "https://github.com/acme/widgets/issues/534"
      )

      epic = described_class.create!(
        user: user,
        repository: repository,
        title: "Workflows as a third subject",
        github_issue_url: "https://github.com/acme/widgets/issues/535",
        description: "Depends-on: #534"
      )

      expect(epic.depends_on_epics).to contain_exactly(prerequisite)
      expect(epic.dependencies.first).not_to be_derived
      expect(epic.pending_epic_dependency_refs).to eq([])
    end

    it "creates dependencies for cross-repository references, comma-separated refs, and synonyms" do
      other_repository = Factories.repository(user: user, owner: "acme", name: "api")
      same_repo_blocker = described_class.create!(
        user: user,
        repository: repository,
        title: "Same repo blocker",
        github_issue_url: "https://github.com/acme/widgets/issues/10"
      )
      cross_repo_blocker = described_class.create!(
        user: user,
        repository: other_repository,
        title: "Cross repo blocker",
        github_issue_url: "https://github.com/acme/api/issues/11"
      )
      synonym_blocker = described_class.create!(
        user: user,
        repository: repository,
        title: "Synonym blocker",
        github_issue_url: "https://github.com/acme/widgets/issues/12"
      )

      epic = described_class.create!(
        user: user,
        repository: repository,
        title: "Dependent",
        github_issue_url: "https://github.com/acme/widgets/issues/13",
        description: "Depends on: #10, acme/api#11\nBlocked-by: #12"
      )

      expect(epic.depends_on_epics).to contain_exactly(same_repo_blocker, cross_repo_blocker, synonym_blocker)
    end

    it "stores unresolved references and resolves them when the target Epic is later ingested" do
      epic = described_class.create!(
        user: user,
        repository: repository,
        title: "Dependent",
        github_issue_url: "https://github.com/acme/widgets/issues/535",
        description: "Depends-on: #534"
      )

      expect(epic.dependencies).to be_empty
      expect(epic.pending_epic_dependency_refs).to eq([
        {
          "owner" => "acme",
          "repo" => "widgets",
          "number" => 534,
          "github_issue_url" => "https://github.com/acme/widgets/issues/534"
        }
      ])

      prerequisite = described_class.create!(
        user: user,
        repository: repository,
        title: "Universal dashboard",
        github_issue_url: "https://github.com/acme/widgets/issues/534"
      )

      expect(epic.reload.depends_on_epics).to contain_exactly(prerequisite)
      expect(epic.pending_epic_dependency_refs).to eq([])
    end

    it "logs and skips parsed dependencies rejected by cycle validation" do
      first = described_class.create!(
        user: user,
        repository: repository,
        title: "First",
        github_issue_url: "https://github.com/acme/widgets/issues/1"
      )
      second = described_class.create!(
        user: user,
        repository: repository,
        title: "Second",
        github_issue_url: "https://github.com/acme/widgets/issues/2"
      )
      EpicDependency.create!(epic: first, depends_on_epic: second)

      expect(Rails.logger).to receive(:warn).with(/rejected parsed Depends-on: acme\/widgets#1.*would create a cycle/)

      second.update!(description: "Depends-on: #1")
      second.send(:seed_parsed_epic_dependencies)

      expect(second.reload.depends_on_epics).to be_empty
    end
  end

  it "keeps ready to in_progress manual and unblocks queued child workflows when started" do
    epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
    job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")
    workflow = Workflows::Initial.instantiate(job: job)

    expect(job).not_to be_dependencies_satisfied
    expect(workflow.first_step.runs).to be_empty

    expect {
      epic.start!
    }.to change { epic.state }.from("ready").to("in_progress")
      .and change(Run, :count).by(1)

    expect(job.reload).to be_queued
    expect(workflow.first_step.runs.first).to be_queued
  end

  describe "#start_implementing!" do
    it "starts a ready Epic through the AASM graph and dispatches held child Jobs" do
      epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
      job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")

      expect(epic.may_start_implementing?(actor: user)).to be(true)
      expect {
        epic.start_implementing!(actor: user)
      }.to change { epic.reload.state }.from("ready").to("in_progress")
        .and change(Run, :count).by(1)

      expect(job.reload).to be_queued
      expect(epic.owner_user).to eq(user)
    end

    it "walks a startable backlog Epic through auto_ready before starting" do
      epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
      job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")
      epic.move_to_backlog!

      expect {
        epic.start_implementing!(actor: user)
      }.to change { epic.reload.state }.from("backlog").to("in_progress")

      expect(job.reload).to be_queued
    end

    it "starts a jobless backlog Epic via the override path so later children dispatch immediately" do
      epic = described_class.create!(user: user, repository: repository, title: "Planless", state: "backlog")

      expect {
        epic.start_implementing!(actor: user)
      }.to change { epic.reload.state }.from("backlog").to("in_progress")

      expect(epic.owner_user).to eq(user)
      expect(epic.releases_jobs_for_execution?).to be(true)
    end

    it "releases dependency-gated children without starting their Runs" do
      epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 19, state: "queued")
      job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

      expect {
        epic.start_implementing!(actor: user)
      }.not_to change(Run, :count)

      expect(job.reload).to be_queued
      expect(job.workflows.queued.count).to eq(1)
    end

    it "refuses in_progress, done, and archived Epics" do
      %w[in_progress done archived].each do |state|
        epic = described_class.create!(user: user, repository: repository, title: "No start from #{state}", state: state)

        expect(epic.may_start_implementing?(actor: user)).to be(false)
        expect {
          epic.start_implementing!(actor: user)
        }.to raise_error(Epic::NotStartable, /cannot start implementing from the #{state} state/)
        expect(epic.reload.state).to eq(state)
      end
    end

    it "refuses Epics claimed by another user but lets the claimant start" do
      claimant = Factories.user(email_address: "claimant@example.com")
      epic = described_class.create!(
        user: user, repository: repository, title: "Claimed", state: "ready",
        owner: claimant, owner_user: claimant, claimed_at: Time.current
      )

      expect(epic.may_start_implementing?(actor: user)).to be(false)
      expect {
        epic.start_implementing!(actor: user)
      }.to raise_error(Epic::NotStartable, /claimed by another user/)
      expect(epic.reload).to be_ready

      expect(epic.may_start_implementing?(actor: claimant)).to be(true)
      epic.start_implementing!(actor: claimant)
      expect(epic.reload).to be_in_progress
    end

    it "refuses product-owner actors" do
      product_owner = Factories.user(role: "product_owner")
      epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")

      expect(epic.may_start_implementing?(actor: product_owner)).to be(false)
      expect {
        epic.start_implementing!(actor: product_owner)
      }.to raise_error(Epic::NotStartable, /Product owners cannot advance/)
      expect(epic.reload).to be_ready
    end

    it "refuses a jobless backlog Epic with unfinished Epic dependencies (no dependency-gate bypass)" do
      blocker = described_class.create!(user: user, repository: repository, title: "Pave the road first", state: "backlog")
      epic = described_class.create!(user: user, repository: repository, title: "Raise the forum", state: "backlog")
      epic.dependencies.create!(depends_on_epic: blocker)

      expect(epic.may_start_implementing?(actor: user)).to be(false)
      expect {
        epic.start_implementing!(actor: user)
      }.to raise_error(Epic::NotStartable, /waiting on Epic dependencies: Pave the road first/)
      expect(epic.reload).to be_backlog
      expect(epic.releases_jobs_for_execution?).to be(false)
    end

    it "refuses a ready Epic with unfinished dependencies and keeps held children blocked" do
      blocker = described_class.create!(user: user, repository: repository, title: "Pave the road first", state: "in_progress")
      epic = described_class.create!(user: user, repository: repository, title: "Raise the forum", state: "ready")
      child = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")
      epic.dependencies.create!(depends_on_epic: blocker)

      expect(epic.may_start_implementing?(actor: user)).to be(false)
      expect {
        expect {
          epic.start_implementing!(actor: user)
        }.to raise_error(Epic::NotStartable, /waiting on Epic dependencies: Pave the road first/)
      }.not_to change(Run, :count)

      expect(epic.reload).to be_ready
      expect(child.reload).to be_blocked_by_epic
    end

    it "names every unfinished dependency, including Job-target dependencies" do
      blocker = described_class.create!(user: user, repository: repository, title: "Pave the road first", state: "backlog")
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 19, state: "queued")
      epic = described_class.create!(user: user, repository: repository, title: "Raise the forum", state: "backlog")
      epic.dependencies.create!(depends_on_epic: blocker)
      epic.dependencies.create!(depends_on_job: prerequisite)

      expect(epic.unfinished_dependency_names).to contain_exactly("Pave the road first", prerequisite.slug)
      expect {
        epic.start_implementing!(actor: user)
      }.to raise_error(Epic::NotStartable, /Pave the road first/)
    end

    it "becomes startable once the blocking Epic completes" do
      blocker = described_class.create!(user: user, repository: repository, title: "Pave the road first", state: "backlog")
      epic = described_class.create!(user: user, repository: repository, title: "Raise the forum", state: "backlog")
      epic.dependencies.create!(depends_on_epic: blocker)

      expect(epic.may_start_implementing?(actor: user)).to be(false)

      blocker.override_state!("done")

      expect(epic.reload.may_start_implementing?(actor: user)).to be(true)
      epic.start_implementing!(actor: user)
      expect(epic.reload).to be_in_progress
    end

    it "refuses a backlog Epic whose child Jobs are still awaiting confirmation" do
      epic = described_class.create!(user: user, repository: repository, title: "Raise the forum", state: "backlog")
      # Attach the triaging child without firing Job callbacks: the factory's
      # create-closed-then-flip dance would auto_ready the Epic in between.
      unconfirmed = Factories.job_record(user: user, repository: repository, issue_number: 21, state: "triaging")
      unconfirmed.update_columns(epic_id: epic.id)

      expect(epic.reload).to be_backlog
      expect(epic.may_start_implementing?(actor: user)).to be(false)
      expect {
        epic.start_implementing!(actor: user)
      }.to raise_error(Epic::NotStartable, /until its child Jobs are confirmed/)
      expect(epic.reload).to be_backlog
      expect(unconfirmed.reload.state).to eq("triaging")
    end
  end

  it "allows ready Epics to move back to backlog without starting child Jobs" do
    epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
    job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")

    expect {
      expect {
        epic.move_to_backlog!
      }.to change { epic.reload.state }.from("ready").to("backlog")
    }.not_to change(Run, :count)

    expect(job.reload).to be_blocked_by_epic
  end

  it "auto-instantiates and starts workflows for direct child Jobs on epic.start!" do
    epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
    job = Factories.job_record(
      user: user, repository: repository, epic: epic,
      kind: "direct", issue_number: nil, issue_title: "t", issue_body: "build the thing",
      state: "blocked_by_epic"
    )

    expect(job.workflows).to be_empty

    expect {
      epic.start!
    }.to change { job.reload.state }.from("blocked_by_epic").to("queued")
      .and change { job.workflows.count }.by(1)
      .and change { job.runs.count }.by(1)

    expect(job.workflows.first.trigger_kind).to eq("initial")
    expect(job.runs.first.prompt).to include("build the thing")
  end

  it "does not let product owners advance Epics to ready or in-progress through guarded transitions" do
    product_owner = Factories.user(role: "product_owner")
    epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
    Factories.job_record(user: user, repository: repository, epic: epic, state: "blocked_by_epic")

    epic.move_to_backlog!

    expect(epic.auto_ready!(actor: product_owner)).to be false
    expect(epic.reload).to be_backlog

    expect {
      epic.override_state!("in_progress", actor: product_owner)
    }.to raise_error(ArgumentError, "Product owners cannot advance Epics beyond backlog.")

    epic.update!(state: "ready")
    expect(epic.start!(actor: product_owner)).to be false
    expect(epic.reload).to be_ready
  end

  it "releases child Jobs from the Epic block without starting them while Job dependencies are unsatisfied" do
    epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 19, state: "queued")
    job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")
    JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

    expect {
      expect {
        epic.start!
      }.to change { job.reload.state }.from("blocked_by_epic").to("queued")
    }.not_to change(Run, :count)

    expect(job.workflows.queued.count).to eq(1)
  end

  it "restores child Epic blocks on override rollback when child Jobs have not started running" do
    epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
    job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")

    epic.start!
    run = job.reload.runs.first

    expect {
      epic.override_state!("ready")
    }.to change { job.reload.state }.from("queued").to("blocked_by_epic")

    expect(run.reload).to be_cancelled
    expect(job.workflows.first).to be_cancelled

    expect {
      epic.override_state!("in_progress")
    }.to change { job.reload.state }.from("blocked_by_epic").to("queued")
      .and change(Run, :count).by(1)
  end

  it "allows in-progress Epics to move back to ready and restores child Epic blocks" do
    epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
    job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")

    epic.start!
    run = job.reload.runs.first

    expect {
      epic.unstart!
    }.to change { epic.reload.state }.from("in_progress").to("ready")
      .and change { job.reload.state }.from("queued").to("blocked_by_epic")

    expect(run.reload).to be_cancelled
    expect(job.workflows.first).to be_cancelled
  end

  it "archives Epics, stamps archived_at, and closes child Jobs with epic_archived reason" do
    epic = described_class.create!(user: user, repository: repository, title: "Retire", state: "ready")
    job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")
    epic.start!
    run = job.reload.runs.first

    freeze_time do
      expect {
        epic.archive!
      }.to change { epic.reload.state }.from("in_progress").to("archived")
        .and change { job.reload.state }.from("queued").to("closed")

      expect(epic.archived_at).to eq(Time.current)
    end

    expect(job.reload.closure_reason).to eq("epic_archived")
    expect(run.reload).to be_cancelled
    expect(job.workflows.first).to be_cancelled
  end

  it "closes child Jobs in any open state when the Epic is archived" do
    epic = described_class.create!(user: user, repository: repository, title: "Mothball", state: "ready")
    queued_job = Factories.job_record(user: user, repository: repository, issue_number: 21, epic: epic, state: "queued")
    triaging_job = Factories.job_record(user: user, repository: repository, issue_number: 22, epic: epic, state: "triaging")
    blocked_job = Factories.job_record(user: user, repository: repository, issue_number: 23, epic: epic, state: "blocked_by_epic")
    already_closed = Factories.job_record(user: user, repository: repository, issue_number: 24, epic: epic)
    already_closed.update!(closure_reason: "pr_merged")
    already_closed.close!

    epic.archive!

    expect(queued_job.reload).to be_closed
    expect(queued_job.closure_reason).to eq("epic_archived")
    expect(triaging_job.reload).to be_closed
    expect(triaging_job.closure_reason).to eq("epic_archived")
    expect(blocked_job.reload).to be_closed
    expect(blocked_job.closure_reason).to eq("epic_archived")
    expect(already_closed.reload.closure_reason).to eq("pr_merged")
  end

  it "auto-completes in-progress Epics when all child Jobs are merged" do
    epic = described_class.create!(user: user, repository: repository, title: "Ship", state: "in_progress")
    first_job = child_job(epic: epic, number: 30)
    last_job = child_job(epic: epic, number: 31)

    freeze_time do
      first_job.update!(closure_reason: "pr_merged")
      first_job.close!

      expect {
        last_job.update!(closure_reason: "external_pr_merged")
        last_job.close!
      }.to change { epic.reload.state }.from("in_progress").to("done")
      expect(epic.done_at).to eq(Time.current)
    end
  end

  it "treats no_changes child Jobs as complete" do
    epic = described_class.create!(user: user, repository: repository, title: "Already shipped", state: "in_progress")
    child_job(epic: epic, number: 32, closure_reason: "no_changes")

    expect(epic).to be_complete
  end

  it "auto-completes in-progress Epics with mixed merged and no_changes child Jobs" do
    epic = described_class.create!(user: user, repository: repository, title: "Mixed landing", state: "in_progress")
    merged_job = child_job(epic: epic, number: 33)
    no_changes_job = child_job(epic: epic, number: 34)

    freeze_time do
      merged_job.update!(closure_reason: "pr_merged")
      merged_job.close!

      expect {
        no_changes_job.update!(closure_reason: "no_changes")
        no_changes_job.close!
      }.to change { epic.reload.state }.from("in_progress").to("done")
      expect(epic.done_at).to eq(Time.current)
    end
  end

  it "blocks invalid AASM transitions but allows documented operator overrides" do
    epic = described_class.create!(user: user, repository: repository, title: "Escape hatch")

    expect(epic.may_auto_complete?).to be false
    expect {
      epic.auto_complete!
    }.not_to change { epic.reload.state }

    freeze_time do
      epic.override_state!("done")
      expect(epic.reload.state).to eq("done")
      expect(epic.done_at).to eq(Time.current)
    end
  end

  it "allows operator override into archived and closes child Jobs" do
    epic = described_class.create!(user: user, repository: repository, title: "Archive override", state: "ready")
    job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")
    epic.start!

    freeze_time do
      expect {
        epic.override_state!("archived")
      }.to change { job.reload.state }.from("queued").to("closed")

      expect(epic.reload).to be_archived
      expect(epic.archived_at).to eq(Time.current)
    end

    expect(job.reload.closure_reason).to eq("epic_archived")
  end

  it "auto-reopens a recently done Epic when a new Job is assigned to it" do
    chat = ChatSession.create!(user: user, repository: repository)
    origin = chat.messages.create!(role: "assistant", content: { "text" => "Epic planning." })
    origin.bookmarks.create!(kind: "epic_origin", label: "Epic planning")

    epic = described_class.create!(user: user, repository: repository, title: "Recent")
    chat.chat_attachments.create!(attachable: epic)
    epic.update!(state: "done", done_at: 5.days.ago)

    job = Job.create!(user: user, repository: repository, issue_number: 501, epic: epic)

    expect(job.reload.epic).to eq(epic)
    expect(epic.reload).to be_in_progress
    expect(chat.messages.where(role: "system").last.content["text"]).to include(job.slug)
  end

  it "leaves stale done Epic matches unattached and suggests an operator confirmation" do
    chat = ChatSession.create!(user: user, repository: repository)
    origin = chat.messages.create!(role: "assistant", content: { "text" => "Epic planning." })
    origin.bookmarks.create!(kind: "epic_origin", label: "Epic planning")

    epic = described_class.create!(user: user, repository: repository, title: "Ancient")
    chat.chat_attachments.create!(attachable: epic)
    epic.update!(state: "done", done_at: 60.days.ago)

    job = Job.create!(user: user, repository: repository, issue_number: 502, epic: epic)

    expect(job.reload.epic).to be_nil
    expect(epic.reload).to be_done
    expect(chat.messages.where(role: "system").last.content["text"]).to eq(
      "This new issue resembles closed #{epic.slug}; reopen and attach?"
    )
    expect(chat.pending_actions.last).to have_attributes(
      action: "reopen_epic_and_attach_job",
      payload: {
        "confidence" => "low",
        "epic_id" => epic.id,
        "job_id" => job.id
      }
    )
  end

  it "handles stale done Epic assignment on an existing Job" do
    chat = ChatSession.create!(user: user, repository: repository)
    origin = chat.messages.create!(role: "assistant", content: { "text" => "Epic planning." })
    origin.bookmarks.create!(kind: "epic_origin", label: "Epic planning")

    epic = described_class.create!(user: user, repository: repository, title: "Old map")
    chat.chat_attachments.create!(attachable: epic)
    epic.update!(state: "done", done_at: 60.days.ago)
    job = Job.create!(user: user, repository: repository, issue_number: 505)

    job.update!(epic: epic)

    expect(job.reload.epic).to be_nil
    expect(chat.pending_actions.last.payload).to include(
      "epic_id" => epic.id,
      "job_id" => job.id
    )
  end

  it "honors the user's configured Epic reopen window" do
    user.update!(epic_reopen_window: 90)
    epic = described_class.create!(user: user, repository: repository, title: "Still recent")
    epic.update!(state: "done", done_at: 60.days.ago)

    job = Job.create!(user: user, repository: repository, issue_number: 503, epic: epic)

    expect(job.reload.epic).to eq(epic)
    expect(epic.reload).to be_in_progress
  end

  it "does not detach an already-attached stale done Epic on unrelated Job saves" do
    epic = described_class.create!(user: user, repository: repository, title: "Historical")
    epic.update!(state: "done", done_at: 60.days.ago)
    job = Job.create!(user: user, repository: repository, issue_number: 504)
    job.update_columns(epic_id: epic.id)

    expect {
      job.update!(issue_title: "Still attached")
    }.not_to change { job.reload.epic_id }
  end

  describe "user_is_repository_member validation" do
    it "rejects an Epic when the creator has no membership on the target repository" do
      outsider = Factories.user(email_address: "outsider@example.com")
      epic = Epic.new(user: outsider, repository: repository, title: "Uninvited")

      expect(epic).not_to be_valid
      expect(epic.errors[:repository]).to include("must have an active membership for the current user")
    end

    it "accepts an Epic when the creator is a collaborator member" do
      collaborator = Factories.user(email_address: "collab@example.com")
      repository.repository_memberships.create!(user: collaborator, role: "collaborator")

      epic = Epic.new(user: collaborator, repository: repository, title: "Invited collaborator work")

      expect(epic).to be_valid
    end

    it "accepts an Epic when the creator is the owner member" do
      epic = Epic.new(user: user, repository: repository, title: "Owner work")

      expect(epic).to be_valid
    end
  end

  describe ".accessible_to" do
    it "includes Epics on repositories where the user has direct membership" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "other", name: "private")
      my_epic = Factories.epic(user: user, repository: repository)
      other_epic = Factories.epic(user: other_user, repository: other_repo)

      result = described_class.accessible_to(user)
      expect(result).to include(my_epic)
      expect(result).not_to include(other_epic)
    end

    it "includes Epics on upstream repos of repositories the user is a member of" do
      upstream_user = Factories.user(email_address: "upstream@example.com")
      upstream = Factories.repository(user: upstream_user, owner: "upstream", name: "lib")
      Factories.repository(user: user, owner: "acme", name: "lib-fork", upstream_repository: upstream)
      upstream_epic = Factories.epic(user: upstream_user, repository: upstream)

      expect(described_class.accessible_to(user)).to include(upstream_epic)
    end

    it "includes Epics on repositories where the user is a collaborator" do
      owner = Factories.user(email_address: "owner@example.com")
      shared_repo = Factories.repository(user: owner, owner: "shared", name: "code")
      shared_repo.repository_memberships.create!(user: user, role: "collaborator")
      shared_epic = Factories.epic(user: owner, repository: shared_repo)

      expect(described_class.accessible_to(user)).to include(shared_epic)
    end
  end

  describe "reconciliation Job creation" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    def make_epic(mode: nil, state: "ready", **attrs)
      described_class.create!(user: user, repository: repository, title: "Recon Epic",
                               reconciliation_mode: mode, state: "backlog", **attrs).tap do |e|
        e.update_columns(state: state) if state != "backlog"
      end
    end

    def add_child(epic, number:, state: "queued")
      Factories.job_record(user: user, repository: repository, epic: epic,
                           issue_number: number, state: state)
    end

    def add_job_dependency(job, depends_on_job)
      JobDependency.create!(
        job: job,
        depends_on_job: depends_on_job,
        source: "manual",
        created_by_user: user
      )
    end

    def add_historical_reconciliation_job(epic)
      Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        issue_number: nil,
        kind: "direct",
        issue_title: "Reconciliation: Recon Epic"
      ).tap do |job|
        epic.update!(reconciliation_job_id: job.id)
      end
    end

    before do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_call_original
    end

    it "does not create a standalone reconciliation Job when the Epic goes in_progress with 2+ sibling Jobs" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "pr", source: "default", note: nil)
      )
      epic = make_epic(state: "ready")
      sibling1 = add_child(epic, number: 1)
      sibling2 = add_child(epic, number: 2)
      add_job_dependency(sibling2, sibling1)

      expect { epic.start!(actor: user) }
        .not_to change { epic.reload.reconciliation_job_id }
      expect(epic.jobs.where("issue_title LIKE ?", "Reconciliation:%")).to be_empty
    end

    it "does not add fan-in dependencies through a reconciliation Job" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "pr", source: "default", note: nil)
      )
      epic = make_epic(state: "ready")
      sibling1 = add_child(epic, number: 1)
      sibling2 = add_child(epic, number: 2)

      epic.start!(actor: user)

      expect(epic.reload.reconciliation_job_id).to be_nil
      expect(JobDependency.where(depends_on_job_id: [ sibling1.id, sibling2.id ])).to be_empty
    end

    it "does not create nonlinear reconciliation Job dependencies" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "pr", source: "default", note: nil)
      )
      epic = make_epic(state: "ready", epic_dependency_policy: "nonlinear")
      sibling1 = add_child(epic, number: 1)
      sibling2 = add_child(epic, number: 2)

      epic.start!(actor: user)

      expect(epic.reload.reconciliation_job_id).to be_nil
      expect(JobDependency.where(depends_on_job_id: [ sibling1.id, sibling2.id ])).to be_empty
    end

    it "skips reconciliation Job creation when mode is 'none' via the Epic column" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "none", source: "epic", note: nil)
      )
      epic = make_epic(mode: "none", state: "in_progress")
      add_child(epic, number: 1)
      add_child(epic, number: 2)

      expect { epic.maybe_create_reconciliation_job! }.not_to change { epic.reload.reconciliation_job_id }
    end

    it "skips reconciliation Job creation when only 1 sibling exists" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "pr", source: "default", note: nil)
      )
      epic = make_epic(state: "in_progress")
      add_child(epic, number: 1)

      expect { epic.maybe_create_reconciliation_job! }.not_to change { epic.reload.reconciliation_job_id }
    end

    it "skips reconciliation Job creation when reconciliation_job_id is already set" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "pr", source: "default", note: nil)
      )
      epic = make_epic(state: "in_progress")
      add_child(epic, number: 1)
      add_child(epic, number: 2)
      historical_recon = add_historical_reconciliation_job(epic)

      expect { epic.maybe_create_reconciliation_job! }.not_to change { epic.reload.reconciliation_job_id }
      expect(epic.reload.reconciliation_job_id).to eq(historical_recon.id)
    end

    it "clears reconciliation_job_id when the reconciliation Job closes" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "pr", source: "default", note: nil)
      )
      epic = make_epic(state: "in_progress")
      add_child(epic, number: 1)
      add_child(epic, number: 2)
      recon_job = add_historical_reconciliation_job(epic)

      recon_job.update_columns(state: "closed", closure_reason: "pr_merged")
      epic.refresh_auto_state!

      expect(epic.reload.reconciliation_job_id).to be_nil
    end

    it "defaults resolved_reconciliation_mode to 'pr' when neither Epic nor .syrus.yml specifies mode" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "pr", source: "default", note: nil)
      )
      epic = make_epic(state: "in_progress")
      expect(epic.resolved_reconciliation_mode).to eq("pr")
    end

    it "Epic column overrides resolved mode" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "none", source: "epic", note: nil)
      )
      epic = make_epic(mode: "none", state: "in_progress")
      expect(epic.resolved_reconciliation_mode).to eq("none")
    end

    it "work_jobs excludes the reconciliation job" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "pr", source: "default", note: nil)
      )
      epic = make_epic(state: "ready")
      sibling1 = add_child(epic, number: 1)
      sibling2 = add_child(epic, number: 2)
      add_historical_reconciliation_job(epic)
      epic.reload

      work_ids = epic.work_jobs.pluck(:id).sort
      expect(work_ids).to contain_exactly(sibling1.id, sibling2.id)
    end

    it "complete? ignores the reconciliation job" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "pr", source: "default", note: nil)
      )
      epic = make_epic(state: "ready")
      sibling1 = add_child(epic, number: 1)
      sibling2 = add_child(epic, number: 2)
      add_historical_reconciliation_job(epic)
      [sibling1, sibling2].each { |j| j.update_columns(state: "closed", closure_reason: "pr_merged") }
      epic.reload

      expect(epic.complete?).to be true
    end

    it "all_jobs_closed? ignores the reconciliation job" do
      allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
        RepoReconciliationPlan::Result.new(mode: "pr", source: "default", note: nil)
      )
      epic = make_epic(state: "ready")
      sibling1 = add_child(epic, number: 1)
      sibling2 = add_child(epic, number: 2)
      add_historical_reconciliation_job(epic)
      [sibling1, sibling2].each { |j| j.update_columns(state: "closed", closure_reason: "pr_merged") }
      epic.reload

      expect(epic.all_jobs_closed?).to be true
    end
  end
end
