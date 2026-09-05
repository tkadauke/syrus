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
  end

  it "populates diff_error when GitHub fails" do
    allow(github).to receive(:compare_commits).and_raise(StandardError, "GitHub unavailable")

    payload = described_class.build(job: job, user: user)

    expect(payload[:files]).to eq([])
    expect(payload[:truncated]).to eq(false)
    expect(payload[:diff_error]).to eq("GitHub unavailable")
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
