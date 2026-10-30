require "rails_helper"

RSpec.describe Coworkers::WorkspaceBrowser do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "workspace") }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-browser", workspace_repo: repository.remote_url) }

  it "drops cached conflict evidence when the recorded chat branch no longer exists" do
    chat = ChatSession.create!(user: owner)
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    chat.messages.create!(
      role: "system",
      content: { "text" => "conflict", "coworker_workspace_conflict" => {
        "branch" => "coworkers/chat/#{coworker.id}-#{chat.id}", "files" => [ "notes.md" ]
      } }
    )
    stub_repository_content(repository, ref: "coworkers/maya-browser", files: { "README.md" => "hello" })

    result = described_class.new(coworker: coworker, repository: repository, user: owner).call

    expect(result[:conflicts]).to be_empty
  end

  it "attributes commits to chats and matching runs without inventing provenance" do
    chat_sha = "a" * 40
    run_sha = "b" * 40
    seed_sha = "c" * 40
    stub_repository_content(repository, ref: "coworkers/maya-browser", files: { "README.md" => "hello" })
    stub_repository_commits(repository, ref: "coworkers/maya-browser", commits: [
      { sha: chat_sha, message: "Update @maya-browser from chat 91" },
      { sha: run_sha, message: "Refresh research notes" },
      { sha: seed_sha, message: "Create coworker home" }
    ])
    job = Factories.job_with_run(user: owner, repository: repository, run_attrs: { head_sha: run_sha.first(12) })
    run = job.runs.sole

    commits = described_class.new(coworker: coworker, repository: repository, user: owner).call.fetch(:commits)

    expect(commits).to contain_exactly(
      include(sha: chat_sha, source: "chat", source_id: 91),
      include(sha: run_sha, source: "run", source_id: run.id),
      include(sha: seed_sha, source: "unattributed", source_id: nil)
    )
    expect(FakeRepositoryContentProvider.calls.any? { |call| call.first == :commits && call.last == 50 }).to be(true)
    expect(FakeRepositoryContentProvider.calls.none? { |call| call.first == :history }).to be(true)
  end
end
