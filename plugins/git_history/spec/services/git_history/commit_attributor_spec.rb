require "rails_helper"

RSpec.describe GitHistory::CommitAttributor do
  let(:repository) { Factories.repository }
  let(:viewer) { repository.user }

  def entry(sha:, subject: "a commit", author_name: "Ada Author", author_email: "ada@example.com",
            committer_name: "Cami Committer", committer_email: "cami@example.com", authored_at: "2026-08-01T00:00:00Z")
    {
      sha: sha, subject: subject, author_name: author_name, author_email: author_email,
      committer_name: committer_name, committer_email: committer_email, authored_at: authored_at
    }
  end

  subject(:attributor) { described_class.new(repository: repository, user: viewer) }

  it "classifies a raw commit with no matching Job as external_push, surfacing git author/committer info" do
    result = attributor.attribute(entry(sha: "a" * 40, subject: "direct push"))

    expect(result[:classification]).to eq("external_push")
    expect(result[:author]).to eq(name: "Ada Author", email: "ada@example.com")
    expect(result[:committer]).to eq(name: "Cami Committer", email: "cami@example.com")
    expect(result).not_to have_key(:job)
  end

  it "classifies a commit matching an external_pr Job's landed_sha as external_pr, not syrus_landed" do
    sha = "b" * 40
    job = Job.create!(
      user: viewer, repository: repository,
      kind: "external_pr", state: "implemented",
      issue_number: nil, external_pr_number: 77, external_pr_author: "octocat",
      landed_sha: sha
    )

    result = attributor.attribute(entry(sha: sha))

    expect(result[:classification]).to eq("external_pr")
    expect(result[:job]).to include(id: job.id)
    expect(result[:pr_number]).to eq(77)
    expect(result[:github_author]).to eq("octocat")
    expect(result[:pr_url]).to eq("https://github.com/#{repository.slug}/pull/77")
    expect(result[:author]).to eq(name: "Ada Author", email: "ada@example.com")
  end

  it "classifies a commit matching a non-external_pr Job's landed_sha as syrus_landed, attributing the creating user" do
    sha = "c" * 40
    job = Factories.job_record(repository: repository, user: viewer, kind: "issue", landed_sha: sha)

    result = attributor.attribute(entry(sha: sha))

    expect(result[:classification]).to eq("syrus_landed")
    expect(result[:job]).to include(id: job.id, slug: job.slug)
    expect(result[:user]).to eq(id: viewer.id, display_name: viewer.display_name)
  end

  it "attaches the Job's Epic when present" do
    sha = "d" * 40
    epic = Factories.epic(repository: repository, user: viewer)
    job = Factories.job_record(repository: repository, user: viewer, kind: "issue", landed_sha: sha, epic: epic)

    result = attributor.attribute(entry(sha: sha))

    expect(result[:epic]).to eq(id: epic.id, slug: epic.slug, title: epic.title)
  end

  it "omits the epic when the Job has none" do
    sha = "e" * 40
    Factories.job_record(repository: repository, user: viewer, kind: "issue", landed_sha: sha)

    result = attributor.attribute(entry(sha: sha))

    expect(result[:epic]).to be_nil
  end

  describe "origin resolution" do
    it "attributes origin to the GitHub issue via input_source_id" do
      sha = "f" * 40
      job = Factories.job_record(
        repository: repository, user: viewer, kind: "issue", landed_sha: sha,
        issue_number: 91, input_source: repository.github_input_source
      )

      result = attributor.attribute(entry(sha: sha))

      expect(result[:origin]).to eq(
        type: "github_issue",
        issue_number: 91,
        issue_url: "https://github.com/#{repository.slug}/issues/91"
      )
      expect(job.input_source_id).to eq(repository.github_input_source.id)
    end

    it "attributes origin to the cron ScheduledTask via scheduled_task_id" do
      sha = "1" + "a" * 39
      scheduled_task = ScheduledTask.create!(
        user: viewer, repository: repository,
        name: "Nightly sweep", prompt: "Do the thing",
        kind: "cron", cron_expression: "0 * * * *",
        minute_offset: 1, pr_pileup_policy: "skip"
      )
      job = Factories.job_record(
        repository: repository, user: viewer, kind: "cron", landed_sha: sha,
        issue_number: nil, scheduled_task: scheduled_task
      )

      result = attributor.attribute(entry(sha: sha))

      expect(result[:origin]).to eq(type: "cron", scheduled_task: { id: scheduled_task.id, name: "Nightly sweep" })
      expect(job.scheduled_task_id).to eq(scheduled_task.id)
    end

    it "attributes origin to chat and includes chat_session_id/title when the viewer can access the chat" do
      sha = "2" + "b" * 39
      job = Factories.job_record(repository: repository, user: viewer, kind: "direct", landed_sha: sha, issue_number: nil)
      chat_session = ChatSession.create!(user: viewer, repository: repository, title: "Ship the thing")
      chat_session.chat_attachments.create!(attachable: job)

      result = attributor.attribute(entry(sha: sha))

      expect(result[:origin]).to eq(type: "chat", chat_session_id: chat_session.id, chat_title: "Ship the thing")
    end

    it "redacts chat_session_id and title when the viewer cannot access the originating chat" do
      other_user = Factories.user
      repository.repository_memberships.create!(user: other_user, role: "read")
      sha = "3" + "c" * 39
      job = Factories.job_record(repository: repository, user: other_user, kind: "direct", landed_sha: sha, issue_number: nil)
      chat_session = ChatSession.create!(user: other_user, repository: repository, title: "Private planning")
      chat_session.chat_attachments.create!(attachable: job)

      result = attributor.attribute(entry(sha: sha))

      expect(result[:origin]).to eq(type: "chat")
      expect(result[:origin]).not_to have_key(:chat_session_id)
      expect(result[:origin]).not_to have_key(:chat_title)
    end

    it "falls back to unknown when the Job has no chat attachment, scheduled task, or input source" do
      sha = "4" + "d" * 39
      Factories.job_record(repository: repository, user: viewer, kind: "direct", landed_sha: sha, issue_number: nil)

      result = attributor.attribute(entry(sha: sha))

      expect(result[:origin]).to eq(type: "unknown")
    end
  end
end
