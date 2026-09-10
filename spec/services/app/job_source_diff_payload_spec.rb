require "rails_helper"

RSpec.describe App::JobSourceDiffPayload do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job(repository: repo, branch_name: "syrus/issue-42") }
  let(:github) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:for).with(repository: repo, user: user).and_return(github)
  end

  it "returns branch refs and changed files" do
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(
        commits: [
          { sha: "deadbeef12345678", short_sha: "deadbee", message: "Change source browser", date: Time.zone.parse("2026-05-01T12:00:00Z") }
        ],
        merge_base_sha: "aabbccdd1234567"
      )
    allow(github).to receive(:compare_files)
      .with("acme/widgets", "aabbccdd1234567", "deadbeef12345678")
      .and_return(
        files: [
          { path: "app/models/user.rb", status: "modified", additions: 4, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" }
        ],
        truncated: false
      )

    payload = described_class.build(job: job, user: user)

    expect(payload).to include(
      job_id: job.id,
      base_ref: "aabbccdd1234567",
      head_ref: "deadbeef12345678",
      merge_base_sha: "aabbccdd1234567",
      default_ref: "main",
      truncated: false,
      diff_error: nil
    )
    expect(payload[:branch_commits]).to contain_exactly(include(
      sha: "deadbeef12345678",
      short_sha: "deadbee",
      message: "Change source browser",
      date: "2026-05-01T12:00:00Z"
    ))
    expect(payload[:files]).to contain_exactly(
      path: "app/models/user.rb",
      status: "modified",
      additions: 4,
      deletions: 1,
      patch: "@@ -1 +1 @@\n-old\n+new"
    )
    expect(payload[:version]).to include(
      version_index: 1,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      label: "All changes",
      reason: "source_diff",
      metadata: { "range_kind" => "all_changes" }
    )
    expect(job.diff_review_versions.last.files_snapshot).to contain_exactly(
      "path" => "app/models/user.rb",
      "status" => "modified",
      "additions" => 4,
      "deletions" => 1,
      "patch" => "@@ -1 +1 @@\n-old\n+new"
    )
  end

  it "populates diff_error when GitHub fails" do
    allow(github).to receive(:compare_commits).and_raise(StandardError, "GitHub unavailable")

    payload = described_class.build(job: job, user: user)

    expect(payload[:files]).to eq([])
    expect(payload[:truncated]).to eq(false)
    expect(payload[:diff_error]).to eq("GitHub unavailable")
  end

  it "diffs a stacked Epic child Job against its parent Job's branch, not the repository default branch" do
    epic = Factories.epic(repository: repo, user: user)
    parent_job = Factories.job(repository: repo, user: user, epic: epic, branch_name: "syrus/job-41", pr_number: 41)
    child_job = Factories.job(repository: repo, user: user, epic: epic, parent_job: parent_job, branch_name: "syrus/job-42")

    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "syrus/job-41", "syrus/job-42")
      .and_return(
        commits: [
          { sha: "cafef00d12345678", short_sha: "cafef00", message: "Only this Job's change", date: Time.zone.parse("2026-05-02T12:00:00Z") }
        ],
        merge_base_sha: "11223344aabbccd"
      )
    allow(github).to receive(:compare_files)
      .with("acme/widgets", "11223344aabbccd", "cafef00d12345678")
      .and_return(
        files: [
          { path: "app/models/widget.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+new" }
        ],
        truncated: false
      )

    payload = described_class.build(job: child_job, user: user)

    expect(payload).to include(
      base_ref: "11223344aabbccd",
      head_ref: "cafef00d12345678",
      merge_base_sha: "11223344aabbccd",
      diff_error: nil
    )
    expect(payload[:files]).to contain_exactly(
      path: "app/models/widget.rb",
      status: "modified",
      additions: 2,
      deletions: 0,
      patch: "@@ -1 +1,2 @@\n+new"
    )
  end

  it "defaults base and head to the default branch when the job has no branch" do
    job.update!(branch_name: nil)
    expect(github).not_to receive(:compare_commits)
    allow(github).to receive(:compare_files)
      .with("acme/widgets", "main", "main")
      .and_return(files: [], truncated: false)

    payload = described_class.build(job: job, user: user)

    expect(payload[:base_ref]).to eq("main")
    expect(payload[:head_ref]).to eq("main")
    expect(payload[:branch_commits]).to eq([])
    expect(payload[:files]).to eq([])
    expect(payload[:diff_error]).to be_nil
  end

  it "persists explicit base/head comparisons so selected diff comments can bind to that version" do
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(commits: [], merge_base_sha: "aabbccdd1234567")
    allow(github).to receive(:compare_files)
      .with("acme/widgets", "old-base", "old-head")
      .and_return(files: [
        { path: "app/models/widget.rb", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n+new" }
      ], truncated: false)

    payload = described_class.build(job: job, user: user, params: { base: "old-base", head: "old-head" })

    expect(payload[:version]).to include(
      version_index: 1,
      base_sha: "old-base",
      head_sha: "old-head",
      reason: "source_diff_selection"
    )
    expect(payload[:versions].map { |version| version[:id] }).to eq([ payload.dig(:version, :id) ])
    expect(job.diff_review_versions.last.files_snapshot).to contain_exactly(
      "path" => "app/models/widget.rb",
      "status" => "modified",
      "additions" => 1,
      "deletions" => 0,
      "patch" => "@@ -1 +1,2 @@\n+new"
    )
  end

  it "reuses an existing version for an explicit SHA pair" do
    existing = DiffReviewVersions::Creator.call(
      job: job,
      base_sha: "old-base",
      head_sha: "old-head",
      files: [],
      label: "Earlier review",
      reason: "initial"
    )
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(commits: [], merge_base_sha: "aabbccdd1234567")
    allow(github).to receive(:compare_files)
      .with("acme/widgets", "old-base", "old-head")
      .and_return(files: [], truncated: false)

    payload = described_class.build(job: job, user: user, params: { base: "old-base", head: "old-head" })

    expect(payload.dig(:version, :id)).to eq(existing.id)
    expect(job.diff_review_versions.count).to eq(1)
  end

  it "defaults to the full branch range when the latest implement repair step changed fewer files" do
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude", state: "succeeded")
    step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "succeeded")
    initial_run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "succeeded",
                              base_sha: "branch-base", head_sha: "initial-head")
    repair_run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "succeeded",
                             base_sha: "initial-head", head_sha: "branch-head")
    initial_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: initial_run,
      base_sha: "branch-base",
      head_sha: "initial-head",
      base_ref: "syrus/parent",
      head_ref: "syrus/issue-42",
      files: [
        { path: "app/services/step_dispatcher.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+backend" },
        { path: "plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx", status: "modified", additions: 10, deletions: 0, patch: "@@ -1 +1,2 @@\n+ui" }
      ],
      reason: "initial"
    )
    repair_step = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: repair_run,
      base_sha: "initial-head",
      head_sha: "branch-head",
      base_ref: "syrus/parent",
      head_ref: "syrus/issue-42",
      files: [
        { path: "db/migrate/20260910113000_add_reusable_input_index_to_target_health_records.rb", status: "added", additions: 6, deletions: 0, patch: "@@ -0,0 +1,6 @@\n+class AddReusableInputIndex" }
      ],
      reason: "initial"
    )
    expect(repair_step.version_index).to be > initial_version.version_index

    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(commits: [
        { sha: "branch-head", short_sha: "branch-h", message: "Current branch", date: Time.zone.parse("2026-05-02T12:00:00Z") },
        { sha: "initial-head", short_sha: "initial", message: "Initial implementation", date: Time.zone.parse("2026-05-01T12:00:00Z") }
      ], merge_base_sha: "branch-base")
    allow(github).to receive(:compare_files)
      .with("acme/widgets", "branch-base", "branch-head")
      .and_return(files: [
        { path: "plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx", status: "modified", additions: 10, deletions: 0, patch: "@@ -1 +1,2 @@\n+ui" },
        { path: "app/services/step_dispatcher.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+backend" },
        { path: "db/migrate/20260910113000_add_reusable_input_index_to_target_health_records.rb", status: "added", additions: 6, deletions: 0, patch: "@@ -0,0 +1,6 @@\n+class AddReusableInputIndex" }
      ], truncated: false)

    payload = described_class.build(job: job, user: user)

    expect(payload[:version]).to include(
      label: "All changes",
      reason: "source_diff",
      base_sha: "branch-base",
      head_sha: "branch-head",
      metadata: { "range_kind" => "all_changes" }
    )
    expect(payload[:files]).to contain_exactly(
      {
        path: "plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx",
        status: "modified",
        additions: 10,
        deletions: 0,
        patch: "@@ -1 +1,2 @@\n+ui"
      },
      {
        path: "db/migrate/20260910113000_add_reusable_input_index_to_target_health_records.rb",
        status: "added",
        additions: 6,
        deletions: 0,
        patch: "@@ -0,0 +1,6 @@\n+class AddReusableInputIndex"
      },
      path: "app/services/step_dispatcher.rb",
      status: "modified",
      additions: 2,
      deletions: 0,
      patch: "@@ -1 +1,2 @@\n+backend"
    )
    expect(payload[:versions].map { |version| version[:id] }).to include(repair_step.id, payload.dig(:version, :id))
  end

  it "promotes an existing full-range run version to All changes when a later repair checkpoint is narrower" do
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude", state: "succeeded")
    step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "succeeded")
    full_range_run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "succeeded",
                                 base_sha: "branch-base", head_sha: "branch-head")
    repair_run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "succeeded",
                             base_sha: "initial-head", head_sha: "branch-head")
    full_range = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: full_range_run,
      base_sha: "branch-base",
      head_sha: "branch-head",
      base_ref: "main",
      head_ref: "syrus/issue-42",
      files: [
        { path: "app/services/step_dispatcher.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+backend" }
      ],
      reason: "initial"
    )
    repair_step = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: repair_run,
      base_sha: "initial-head",
      head_sha: "branch-head",
      base_ref: "main",
      head_ref: "syrus/issue-42",
      files: [
        { path: "db/migrate/repair.rb", status: "added", additions: 6, deletions: 0, patch: "@@ -0,0 +1,6 @@\n+class Repair" }
      ],
      reason: "initial"
    )
    expect(repair_step.version_index).to be > full_range.version_index

    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(commits: [
        { sha: "branch-head", short_sha: "branch-h", message: "Current branch", date: Time.zone.parse("2026-05-02T12:00:00Z") }
      ], merge_base_sha: "branch-base")
    allow(github).to receive(:compare_files)
      .with("acme/widgets", "branch-base", "branch-head")
      .and_return(files: [
        { path: "app/services/step_dispatcher.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+backend" },
        { path: "db/migrate/repair.rb", status: "added", additions: 6, deletions: 0, patch: "@@ -0,0 +1,6 @@\n+class Repair" }
      ], truncated: false)

    payload = described_class.build(job: job, user: user)
    promoted = full_range.reload

    expect(payload.dig(:version, :id)).to eq(full_range.id)
    expect(promoted).to have_attributes(label: "All changes", reason: "source_diff")
    expect(promoted.metadata).to include("range_kind" => "all_changes")
    expect(promoted.files_snapshot.map { |file| file["path"] }).to contain_exactly("app/services/step_dispatcher.rb", "db/migrate/repair.rb")
    expect(App::DiffReviewVersionsPayload.index(job: job)[:latest_version_id]).to eq(full_range.id)
    expect(payload[:versions].map { |version| version[:id] }).to include(repair_step.id, full_range.id)
  end

  describe "preview diff fixture" do
    let(:fixture) do
      {
        "base_ref" => "main",
        "head_ref" => "deadbeef12345678",
        "merge_base_sha" => "aabbccdd1234567",
        "branch_commits" => [
          { "sha" => "deadbeef12345678", "short_sha" => "deadbee", "message" => "Seed fixture commit", "date" => "2026-05-01T12:00:00Z" }
        ],
        "files" => [
          { "path" => "app/models/user.rb", "status" => "modified", "additions" => 4, "deletions" => 1, "patch" => "@@ -1 +1 @@\n-old\n+new" }
        ]
      }
    end

    before { job.update!(branch_name: nil, diff_fixture: fixture) }

    it "returns fixture-backed file/patch data in development without touching GitHub" do
      allow(Rails.env).to receive(:development?).and_return(true)
      expect(GithubClient).not_to receive(:for)

      payload = described_class.build(job: job, user: user)

      expect(payload).to include(
        job_id: job.id,
        base_ref: "main",
        head_ref: "deadbeef12345678",
        merge_base_sha: "aabbccdd1234567",
        default_ref: "main",
        truncated: false,
        diff_error: nil
      )
      expect(payload[:branch_commits]).to contain_exactly(include(
        sha: "deadbeef12345678",
        short_sha: "deadbee",
        message: "Seed fixture commit",
        date: "2026-05-01T12:00:00Z"
      ))
      expect(payload[:files]).to contain_exactly(
        path: "app/models/user.rb",
        status: "modified",
        additions: 4,
        deletions: 1,
        patch: "@@ -1 +1 @@\n-old\n+new"
      )
      expect(payload[:version]).to include(
        version_index: 1,
        base_sha: "aabbccdd1234567",
        head_sha: "deadbeef12345678",
        label: "Preview fixture",
        reason: "diff_fixture"
      )
      expect(job.diff_review_versions.last.files_snapshot).to contain_exactly(
        "path" => "app/models/user.rb",
        "status" => "modified",
        "additions" => 4,
        "deletions" => 1,
        "patch" => "@@ -1 +1 @@\n-old\n+new"
      )
    end

    it "does not activate outside development even when the fixture column is populated" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(github).to receive(:compare_commits).and_return(commits: [], merge_base_sha: nil)
      allow(github).to receive(:compare_files)
        .with("acme/widgets", "main", "main")
        .and_return(files: [], truncated: false)

      payload = described_class.build(job: job, user: user)

      expect(payload[:files]).to eq([])
      expect(payload[:diff_error]).to be_nil
      expect(payload[:base_ref]).to eq("main")
    end

    it "does not become a generic bypass for jobs without a fixture" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "acme", name: "no-token-repo", default_branch: "main")
      other_job = Factories.job(repository: other_repo, branch_name: nil)
      allow(Rails.env).to receive(:development?).and_return(true)

      payload = described_class.build(job: other_job, user: other_user)

      expect(payload[:diff_error]).to eq("GitHub token not configured. Add one in Settings to browse source.")
      expect(payload[:files]).to eq([])
    end
  end
end
