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
    stub_repository_diff(repo, base: "aabbccdd1234567", head: "deadbeef12345678",
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
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
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
      patch: "@@ -1 +1 @@\n-old\n+new",
      is_image: false
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

  # GitHub lists at most 300 files per comparison. The viewer always showed
  # that partial list with a banner; the content contract refuses to pass it
  # off as complete, so the payload opts into the partial answer explicitly.
  it "still shows a truncated comparison, flagged, and uses the UI's status names" do
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(commits: [ { sha: "head1234", short_sha: "head123", message: "m", date: Time.current } ], merge_base_sha: "base1234")
    stub_repository_diff(repo, base: "base1234", head: "head1234", truncated: true, files: [
      { path: "gone.rb", status: "removed", additions: 0, deletions: 3, patch: "@@ -1,3 +0,0 @@" }
    ])

    payload = described_class.build(job: job, user: user)

    expect(payload[:truncated]).to be(true)
    expect(payload[:diff_error]).to be_nil
    expect(payload[:files]).to contain_exactly(include(path: "gone.rb", status: "removed", deletions: 3))
  end

  it "populates diff_error when GitHub fails" do
    allow(github).to receive(:compare_commits).and_raise(StandardError, "GitHub unavailable")

    payload = described_class.build(job: job, user: user)

    expect(payload[:files]).to eq([])
    expect(payload[:truncated]).to eq(false)
    expect(payload[:diff_error]).to eq("GitHub unavailable")
  end

  it "flags patch-less image files by extension and leaves other patch-less files unflagged" do
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(
        commits: [
          { sha: "deadbeef12345678", short_sha: "deadbee", message: "Add screenshot", date: Time.zone.parse("2026-05-01T12:00:00Z") }
        ],
        merge_base_sha: "aabbccdd1234567"
      )
    stub_repository_diff(repo, base: "aabbccdd1234567", head: "deadbeef12345678",
        files: [
          { path: "app/assets/images/logo.png", status: "modified", additions: 0, deletions: 0, patch: nil },
          { path: "app/assets/images/UPPER.PNG", status: "added", additions: 0, deletions: 0, patch: nil },
          { path: "vendor/some.bin", status: "modified", additions: 0, deletions: 0, patch: nil },
          { path: "app/models/user.rb", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" }
        ],
        truncated: false
      )

    payload = described_class.build(job: job, user: user)

    expect(payload[:files]).to contain_exactly(
      { path: "app/assets/images/logo.png", status: "modified", additions: 0, deletions: 0, patch: nil, is_image: true },
      { path: "app/assets/images/UPPER.PNG", status: "added", additions: 0, deletions: 0, patch: nil, is_image: true },
      { path: "vendor/some.bin", status: "modified", additions: 0, deletions: 0, patch: nil, is_image: false },
      { path: "app/models/user.rb", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new", is_image: false }
    )
  end

  it "does not flag an image-extension file as binary when GitHub did return a patch" do
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(commits: [], merge_base_sha: "aabbccdd1234567")
    stub_repository_diff(repo, base: "old-base", head: "old-head",
        files: [
          { path: "app/assets/images/diagram.svg", status: "modified", additions: 3, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" }
        ],
        truncated: false
      )

    payload = described_class.build(job: job, user: user, params: { base: "old-base", head: "old-head" })

    expect(payload[:files]).to contain_exactly(
      path: "app/assets/images/diagram.svg",
      status: "modified",
      additions: 3,
      deletions: 1,
      patch: "@@ -1 +1 @@\n-old\n+new",
      is_image: false
    )
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
    stub_repository_diff(repo, base: "11223344aabbccd", head: "cafef00d12345678",
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
      patch: "@@ -1 +1,2 @@\n+new",
      is_image: false
    )
  end

  it "defaults base and head to the default branch when the job has no branch" do
    job.update!(branch_name: nil)
    expect(github).not_to receive(:compare_commits)
    stub_repository_diff(repo, base: "main", head: "main", files: [], truncated: false)

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
    stub_repository_diff(repo, base: "old-base", head: "old-head", files: [
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
    stub_repository_diff(repo, base: "old-base", head: "old-head", files: [], truncated: false)

    payload = described_class.build(job: job, user: user, params: { base: "old-base", head: "old-head" })

    expect(payload.dig(:version, :id)).to eq(existing.id)
    expect(job.diff_review_versions.count).to eq(1)
  end

  it "reuses the same explicit SHA pair across repeated source diff payload fetches" do
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(commits: [], merge_base_sha: "aabbccdd1234567")
    stub_repository_diff(repo, base: "old-base", head: "old-head", files: [
        { path: "app/models/widget.rb", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n+new" }
      ], truncated: false)

    first_payload = described_class.build(job: job, user: user, params: { base: "old-base", head: "old-head" })
    second_payload = described_class.build(job: job, user: user, params: { base: "old-base", head: "old-head" })

    expect(second_payload.dig(:version, :id)).to eq(first_payload.dig(:version, :id))
    expect(job.diff_review_versions.pluck(:base_sha, :head_sha)).to eq([ [ "old-base", "old-head" ] ])
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
    stub_repository_diff(repo, base: "branch-base", head: "branch-head", files: [
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
        patch: "@@ -1 +1,2 @@\n+ui",
        is_image: false
      },
      {
        path: "db/migrate/20260910113000_add_reusable_input_index_to_target_health_records.rb",
        status: "added",
        additions: 6,
        deletions: 0,
        patch: "@@ -0,0 +1,6 @@\n+class AddReusableInputIndex",
        is_image: false
      },
      path: "app/services/step_dispatcher.rb",
      status: "modified",
      additions: 2,
      deletions: 0,
      patch: "@@ -1 +1,2 @@\n+backend",
      is_image: false
    )
    expect(payload[:versions].map { |version| version[:id] }).to include(repair_step.id, payload.dig(:version, :id))
  end

  it "uses the latest stored review version instead of diffing old base to main when the branch has no commits ahead" do
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude", state: "succeeded")
    step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "succeeded")
    run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "succeeded",
                      base_sha: "branch-base", head_sha: "implemented-head")
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "branch-base",
      head_sha: "implemented-head",
      base_ref: "main",
      head_ref: "syrus/issue-42",
      files: [
        { path: "app/models/implemented.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+implemented" }
      ],
      reason: "initial"
    )
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(commits: [], merge_base_sha: "old-main-base", status: "identical")
    forbid_repository_changes!

    payload = described_class.build(job: job, user: user)

    expect(payload).to include(
      base_ref: "main",
      head_ref: "syrus/issue-42",
      merge_base_sha: "old-main-base",
      diff_error: nil
    )
    expect(payload.dig(:version, :id)).to eq(version.id)
    expect(payload[:files]).to contain_exactly(
      path: "app/models/implemented.rb",
      status: "modified",
      additions: 2,
      deletions: 0,
      patch: "@@ -1 +1,2 @@\n+implemented",
      is_image: false
    )
    expect(job.diff_review_versions.count).to eq(1)
  end

  it "falls back to a stored review version when GitHub cannot compare the current branch" do
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude", state: "succeeded")
    step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "succeeded")
    run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "succeeded",
                      base_sha: "branch-base", head_sha: "implemented-head")
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "branch-base",
      head_sha: "implemented-head",
      base_ref: "main",
      head_ref: "syrus/issue-42",
      files: [
        { path: "app/models/implemented.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+implemented" }
      ],
      reason: "initial"
    )
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_raise(StandardError, "GitHub unavailable")
    forbid_repository_changes!

    payload = described_class.build(job: job, user: user)

    expect(payload[:diff_error]).to be_nil
    expect(payload.dig(:version, :id)).to eq(version.id)
    expect(payload[:files]).to contain_exactly(
      path: "app/models/implemented.rb",
      status: "modified",
      additions: 2,
      deletions: 0,
      patch: "@@ -1 +1,2 @@\n+implemented",
      is_image: false
    )
  end

  it "does not create an All changes version with main as the head when an ahead branch has no stored review version" do
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(commits: [], merge_base_sha: "old-main-base", status: "identical")
    forbid_repository_changes!

    payload = described_class.build(job: job, user: user)

    expect(payload).to include(
      base_ref: "old-main-base",
      head_ref: "old-main-base",
      merge_base_sha: "old-main-base",
      files: [],
      version: nil,
      versions: []
    )
    expect(job.diff_review_versions).to be_empty
  end

  it "creates a new All changes version instead of repairing a legacy empty version in place" do
    legacy = DiffReviewVersion.create!(
      job: job,
      version_index: 1,
      base_sha: "main",
      head_sha: "main",
      source_key: "workflow:none:run:none",
      label: "All changes",
      reason: "source_diff",
      files_snapshot: [],
      metadata: { "range_kind" => "all_changes" }
    )
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(commits: [
        { sha: "branch-head", short_sha: "branch-h", message: "Current branch", date: Time.zone.parse("2026-05-02T12:00:00Z") }
      ], merge_base_sha: "branch-base")
    stub_repository_diff(repo, base: "branch-base", head: "branch-head", files: [
        { path: "app/models/implemented.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+implemented" }
      ], truncated: false)

    payload = described_class.build(job: job, user: user)

    expect(payload.dig(:version, :id)).not_to eq(legacy.id)
    expect(payload[:files].map { |file| file[:path] }).to eq([ "app/models/implemented.rb" ])
    expect(legacy.reload).to have_attributes(base_sha: "main", head_sha: "main", files_snapshot: [])

    new_version = job.diff_review_versions.find(payload.dig(:version, :id))
    expect(new_version).to have_attributes(
      base_sha: "branch-base",
      head_sha: "branch-head",
      base_ref: "main",
      head_ref: "syrus/issue-42",
      label: "All changes",
      reason: "source_diff"
    )
    expect(new_version.files_snapshot.map { |file| file["path"] }).to eq([ "app/models/implemented.rb" ])
    expect(DiffReviewVersion.default_for_review(job)).to eq(new_version)
  end

  it "reuses an existing run version unchanged when its range exactly matches the current diff" do
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
    stub_repository_diff(repo, base: "branch-base", head: "branch-head", files: [
        { path: "app/services/step_dispatcher.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+backend" },
        { path: "db/migrate/repair.rb", status: "added", additions: 6, deletions: 0, patch: "@@ -0,0 +1,6 @@\n+class Repair" }
      ], truncated: false)

    payload = described_class.build(job: job, user: user)
    reused = full_range.reload

    expect(payload.dig(:version, :id)).to eq(full_range.id)
    expect(reused.reason).to eq("initial")
    expect(reused.files_snapshot.map { |file| file["path"] }).to eq([ "app/services/step_dispatcher.rb" ])
    expect(payload[:versions].map { |version| version[:id] }).to include(repair_step.id, full_range.id)
  end

  it "creates a new All changes version instead of overwriting the existing one when the branch head changes" do
    claude_workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude", state: "succeeded")
    claude_step = Step.create!(workflow: claude_workflow, kind: "implement", position: 1, state: "succeeded")
    claude_run = Run.create!(job: job, step: claude_step, trigger_kind: "initial", state: "succeeded",
                             base_sha: "base-sha", head_sha: "claude-head")

    codex_workflow = Workflow.create!(job: job, user: user, trigger_kind: "retry", agent_provider: "codex", state: "succeeded")
    codex_step = Step.create!(workflow: codex_workflow, kind: "implement", position: 1, state: "succeeded")
    codex_run = Run.create!(job: job, step: codex_step, trigger_kind: "retry", state: "succeeded",
                            base_sha: "base-sha", head_sha: "codex-head")

    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(
        { commits: [ { sha: "claude-head", short_sha: "claude-h", message: "Claude implementation", date: Time.zone.parse("2026-05-01T12:00:00Z") } ], merge_base_sha: "base-sha" },
        { commits: [ { sha: "codex-head", short_sha: "codex-he", message: "Codex retry", date: Time.zone.parse("2026-05-02T12:00:00Z") } ], merge_base_sha: "base-sha" }
      )
    stub_repository_diff(repo, base: "base-sha", head: "claude-head", files: [
        { path: "app/models/widget.rb", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n+claude" }
      ], truncated: false)
    stub_repository_diff(repo, base: "base-sha", head: "codex-head", files: [
        { path: "app/models/widget.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+codex" }
      ], truncated: false)

    first_payload = described_class.build(job: job, user: user)
    second_payload = described_class.build(job: job, user: user)

    all_changes_versions = job.diff_review_versions.where(reason: "source_diff").order(:version_index)
    expect(all_changes_versions.count).to eq(2)
    expect(second_payload.dig(:version, :id)).not_to eq(first_payload.dig(:version, :id))
    expect(second_payload[:versions].size).to eq(2)

    first_version, second_version = all_changes_versions.to_a
    expect(first_payload.dig(:version, :id)).to eq(first_version.id)
    expect(second_payload.dig(:version, :id)).to eq(second_version.id)

    # The Job's first "All changes" computation stays exactly as it was
    # persisted -- it is never rewritten by a later, unrelated request.
    expect(first_version.reload).to have_attributes(
      base_sha: "base-sha",
      head_sha: "claude-head",
      workflow_id: claude_workflow.id,
      run_id: claude_run.id,
      trigger_kind: "initial",
      label: "All changes"
    )
    expect(second_version).to have_attributes(
      base_sha: "base-sha",
      head_sha: "codex-head",
      workflow_id: codex_workflow.id,
      run_id: codex_run.id,
      trigger_kind: "retry",
      label: "All changes"
    )
    expect(second_payload[:version]).to include(base_sha: "base-sha", head_sha: "codex-head")
  end

  it "never mutates a persisted DiffReviewVersion row when recomputing the current diff across repeated reads" do
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(
        { commits: [ { sha: "head-one", short_sha: "head-one", message: "First", date: Time.zone.parse("2026-05-01T12:00:00Z") } ], merge_base_sha: "base-sha" },
        { commits: [ { sha: "head-one", short_sha: "head-one", message: "First", date: Time.zone.parse("2026-05-01T12:00:00Z") } ], merge_base_sha: "base-sha" },
        { commits: [ { sha: "head-two", short_sha: "head-two", message: "Second", date: Time.zone.parse("2026-05-02T12:00:00Z") } ], merge_base_sha: "base-sha" }
      )
    stub_repository_diff(repo, base: "base-sha", head: "head-one", files: [
        { path: "app/models/widget.rb", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n+one" }
      ], truncated: false)
    stub_repository_diff(repo, base: "base-sha", head: "head-two", files: [
        { path: "app/models/widget.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+two" }
      ], truncated: false)

    first_payload = described_class.build(job: job, user: user)
    second_payload = described_class.build(job: job, user: user)

    # Same base/head across two consecutive calls (no underlying branch
    # change) -- the same row is reused, untouched.
    expect(second_payload.dig(:version, :id)).to eq(first_payload.dig(:version, :id))
    first_version = job.diff_review_versions.find(first_payload.dig(:version, :id))
    expect(first_version).to have_attributes(base_sha: "base-sha", head_sha: "head-one")
    expect(first_version.files_snapshot.map { |file| file["path"] }).to eq([ "app/models/widget.rb" ])
    original_updated_at = first_version.updated_at

    # The branch advances to a new head -- a fresh row is created for the
    # new current diff, and the earlier historical row is left untouched.
    third_payload = described_class.build(job: job, user: user)

    expect(third_payload.dig(:version, :id)).not_to eq(first_version.id)
    expect(first_version.reload).to have_attributes(base_sha: "base-sha", head_sha: "head-one", updated_at: original_updated_at)
    expect(first_version.files_snapshot.map { |file| file["path"] }).to eq([ "app/models/widget.rb" ])

    new_version = job.diff_review_versions.find(third_payload.dig(:version, :id))
    expect(new_version).to have_attributes(base_sha: "base-sha", head_sha: "head-two")
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
        patch: "@@ -1 +1 @@\n-old\n+new",
        is_image: false
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
      stub_repository_diff(repo, base: "main", head: "main", files: [], truncated: false)

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
