require "rails_helper"

RSpec.describe Epic do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
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

  it "keeps child Job epic titles in sync when renamed" do
    epic = Factories.epic(title: "Migration train")
    job = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic)

    epic.update!(title: "Landing train")

    expect(job.reload.epic_title).to eq("Landing train")
  end

  it "rejects unknown auto-approval modes" do
    epic = Factories.epic
    epic.auto_approve_mode = "always"
    expect(epic).not_to be_valid
    expect(epic.errors[:auto_approve_mode]).to be_present
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
    expect(epic.display_number).to eq("EPIC-#{epic.number}")

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

  it "archives Epics, stamps archived_at, and restores child Epic blocks" do
    epic = described_class.create!(user: user, repository: repository, title: "Retire", state: "ready")
    job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")
    epic.start!
    run = job.reload.runs.first

    expect(epic).to receive(:restore_child_epic_blocks!).and_call_original

    freeze_time do
      expect {
        epic.archive!
      }.to change { epic.reload.state }.from("in_progress").to("archived")
        .and change { job.reload.state }.from("queued").to("blocked_by_epic")

      expect(epic.archived_at).to eq(Time.current)
    end

    expect(run.reload).to be_cancelled
    expect(job.workflows.first).to be_cancelled
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

  it "allows operator override into archived with child Epic block restoration" do
    epic = described_class.create!(user: user, repository: repository, title: "Archive override", state: "ready")
    job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic, state: "blocked_by_epic")
    epic.start!

    freeze_time do
      expect {
        epic.override_state!("archived")
      }.to change { job.reload.state }.from("queued").to("blocked_by_epic")

      expect(epic.reload).to be_archived
      expect(epic.archived_at).to eq(Time.current)
    end
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
    expect(chat.messages.where(role: "system").last.content["text"]).to include("JOB-#{job.id}")
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
      "This new issue resembles closed #{epic.display_number}; reopen and attach?"
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
end
