require "rails_helper"

RSpec.describe CognitiveEngagementEvents::SourceIngestor do
  let(:user) { Factories.user(email_address: "owner@example.com", github_handle: "owner") }
  let!(:reviewer) { Factories.user(email_address: "reviewer@example.com", github_handle: "reviewer") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:empty_commit_source) { commit_source([]) }

  def ingest(commit_source: empty_commit_source)
    described_class.call(repository: repository, commit_source: commit_source)
  end

  def commit_source(commits)
    Class.new do
      define_method(:initialize) { |records| @records = records }
      define_method(:each_commit) { |&block| @records.each(&block) }
    end.new(commits)
  end

  def commit(sha:, author_name:, author_email:, files:, authored_at: Time.zone.parse("2026-09-28 12:00:00 UTC"))
    CognitiveEngagementEvents::HumanCommitSource::Commit.new(
      sha: sha,
      author_name: author_name,
      author_email: author_email,
      authored_at: authored_at,
      files: files.map { |path, additions, deletions| file_change(path: path, additions: additions, deletions: deletions) }
    )
  end

  def file_change(path:, additions:, deletions:)
    CognitiveEngagementEvents::HumanCommitSource::FileChange.new(path: path, additions: additions, deletions: deletions)
  end

  def job_record(**attrs)
    Factories.job_record(user: user, repository: repository, **attrs)
  end

  def diff_version(job, files: default_files_snapshot, created_at: Time.zone.parse("2026-09-28 10:00:00 UTC"))
    version = DiffReviewVersion.create!(
      job: job,
      version_index: DiffReviewVersion.next_index_for(job),
      base_sha: "base-#{SecureRandom.hex(2)}",
      head_sha: "head-#{SecureRandom.hex(2)}",
      source_key: "spec-#{SecureRandom.hex(4)}",
      label: "Spec diff",
      reason: "source_diff",
      files_snapshot: files,
      metadata: {}
    )
    version.update_columns(created_at: created_at, updated_at: created_at)
    version
  end

  def default_files_snapshot
    [
      {
        "path" => "app/models/widget.rb",
        "status" => "modified",
        "additions" => 2,
        "deletions" => 1,
        "patch" => [
          "@@ -10,3 +10,4 @@",
          " keep",
          "-old_call",
          "+new_call",
          "+another_call",
          " done"
        ].join("\n")
      }
    ]
  end

  it "ingests diff review comments as strong range engagement and remains idempotent" do
    job = job_record
    version = diff_version(job)
    comment = DiffReviewComment.create!(
      job: job,
      user: reviewer,
      diff_review_version: version,
      surface: "job_diff",
      anchor_kind: "line",
      path: "app/models/widget.rb",
      side: "right",
      new_line: 12,
      body: "This is the important line.",
      state: "submitted"
    )

    expect { 2.times { ingest } }.to change { CognitiveEngagementEvent.count }.by(1)

    event = CognitiveEngagementEvent.find_by!(source_type: "diff_review_comment")
    expect(event).to have_attributes(
      user: reviewer,
      diff_review_version: version,
      evidence_key: "diff_review_comment:#{comment.id}",
      engagement_kind: "reviewed",
      anchor_kind: "range",
      path: "app/models/widget.rb",
      side: "right",
      start_line: 12,
      end_line: 12,
      quality: "high"
    )
    expect(event.confidence).to eq(BigDecimal("0.95"))
  end

  it "skips approval ingestion when no diff review version is available" do
    job = job_record
    JobApproval.create!(job: job, user: reviewer, approved_at: Time.zone.parse("2026-09-28 11:00:00 UTC"))

    expect { ingest }.not_to change { CognitiveEngagementEvent.count }
  end

  it "records approvals only against changed ranges with low confidence" do
    job = job_record
    version = diff_version(job)
    approval = JobApproval.create!(job: job, user: reviewer, approved_at: Time.zone.parse("2026-09-28 11:00:00 UTC"))

    ingest

    events = CognitiveEngagementEvent.where(source_type: "job_approval", evidence_key: "job_approval:#{approval.id}").order(:side, :start_line)
    expect(events.map { |event| [ event.path, event.side, event.start_line, event.end_line ] }).to eq([
      [ "app/models/widget.rb", "left", 11, 11 ],
      [ "app/models/widget.rb", "right", 11, 12 ]
    ])
    expect(events.map(&:diff_review_version).uniq).to eq([ version ])
    expect(events.map(&:quality).uniq).to eq([ "rubber_stamp" ])
    expect(events.map(&:confidence).uniq).to eq([ BigDecimal("0.25") ])
    expect(events.map(&:weight).uniq).to eq([ BigDecimal("0.2") ])
  end

  it "uses jobs.approved_* as a conservative changed-range approval fallback" do
    job = job_record
    diff_version(job)
    approved_at = Time.zone.parse("2026-09-28 11:00:00 UTC")
    job.update_columns(
      state: "approved",
      approved_at: approved_at,
      approved_by_user_id: reviewer.id,
      approved_via: "operator",
      approval_evidence: { "note" => "reviewed in the UI" }
    )

    ingest

    events = CognitiveEngagementEvent.where(source_type: "job_approval", evidence_type: "Job").order(:side, :start_line)
    expect(events.size).to eq(2)
    expect(events).to all(have_attributes(user: reviewer, quality: "rubber_stamp"))
    expect(events.map(&:anchor_kind).uniq).to eq([ "range" ])
    expect(events.map { |event| event.metadata["approval_source"] }.uniq).to eq([ "job_snapshot" ])
  end

  it "ingests PR review comments when a file and line anchor can be recovered" do
    job = job_record
    diff_version(job)
    comment = PrReviewComment.create!(
      job: job,
      pr_type: "direct",
      comment_kind: "review",
      github_comment_id: 12_345,
      github_handle: "reviewer",
      body: "Please revisit app/models/widget.rb#L12.",
      comment_created_at: Time.zone.parse("2026-09-28 11:00:00 UTC")
    )

    ingest

    event = CognitiveEngagementEvent.find_by!(source_type: "pr_review_comment", evidence_key: "pr_review_comment:#{comment.id}")
    expect(event).to have_attributes(
      user: reviewer,
      evidence_key: "pr_review_comment:#{comment.id}",
      engagement_kind: "discussed",
      anchor_kind: "range",
      path: "app/models/widget.rb",
      side: "right",
      start_line: 12,
      end_line: 12
    )
  end

  it "skips unanchored PR review comments instead of inventing range evidence" do
    job = job_record
    diff_version(job)
    PrReviewComment.create!(
      job: job,
      pr_type: "direct",
      comment_kind: "issue",
      github_comment_id: 12_346,
      github_handle: "reviewer",
      body: "Looks good overall.",
      comment_created_at: Time.zone.parse("2026-09-28 11:00:00 UTC")
    )

    expect { ingest }.not_to change { CognitiveEngagementEvent.count }
  end

  it "ingests known human-authored commits and skips known agent or bot-authored commits" do
    agent_job = job_record(issue_number: 99)
    LandedCommit.create!(landable: agent_job, sha: "agent-sha", kind: "implementation", position: 0)
    source = commit_source([
      commit(
        sha: "human-sha",
        author_name: "Reviewer",
        author_email: "reviewer@example.com",
        files: [ [ "app/models/human.rb", 3, 1 ] ]
      ),
      commit(
        sha: "agent-sha",
        author_name: "Reviewer",
        author_email: "reviewer@example.com",
        files: [ [ "app/models/agent.rb", 5, 0 ] ]
      ),
      commit(
        sha: "bot-sha",
        author_name: "tkadauke-syrus[bot]",
        author_email: "tkadauke-syrus[bot]@users.noreply.github.com",
        files: [ [ "app/models/bot.rb", 1, 0 ] ]
      )
    ])

    expect { 2.times { ingest(commit_source: source) } }.to change { CognitiveEngagementEvent.count }.by(1)

    event = CognitiveEngagementEvent.find_by!(source_type: "authored_line")
    expect(event).to have_attributes(
      user: reviewer,
      engagement_kind: "authored",
      evidence_key: "git_commit:human-sha:app/models/human.rb",
      commit_sha: "human-sha",
      anchor_kind: "file",
      path: "app/models/human.rb",
      quality: "high"
    )
    expect(event.metadata).to include("additions" => 3, "deletions" => 1)
  end
end
