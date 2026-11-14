require "rails_helper"

RSpec.describe Coworkers::BranchRetentionSweep do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-retention",
      workspace_repo: repository.remote_url)
  end
  let(:remote) { instance_double(Coworkers::RemoteWorkspace) }
  let(:now) { Time.zone.parse("2026-11-14 12:00:00") }

  it "deletes only eligible merged refs and respects the per-run cap" do
    refs = 3.times.map do |index|
      { branch: "coworkers/run/#{coworker.id}-#{90_000 + index}", sha: index.to_s * 40,
        committed_at: now - 8.days }
    end
    allow(remote).to receive(:merged_run_refs).and_return(refs)
    allow(remote).to receive(:guarded_delete_if_matches!)

    deleted = described_class.call(coworker:, remote:, now:, limit: 2)

    expect(deleted).to eq(2)
    expect(remote).to have_received(:guarded_delete_if_matches!).twice
  end

  it "keeps recent existing-workflow and unresolved conflict refs" do
    workflow = Factories.job_with_run(user: owner, repository: repository).workflows.sole
    chat = ChatSession.create!(user: owner)
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    protected_branch = "coworkers/run/#{coworker.id}-99999"
    Coworkers::WorkspaceConflict.create!(chat_session: chat, repository:, source_branch: protected_branch,
      files: [ "notes.md" ], versions: { "notes.md" => "conflict" }, expires_at: 1.hour.from_now)
    refs = [
      { branch: "coworkers/run/#{coworker.id}-#{workflow.id}", sha: "a" * 40, committed_at: now - 1.day },
      { branch: protected_branch, sha: "b" * 40, committed_at: now - 30.days }
    ]
    allow(remote).to receive(:merged_run_refs).and_return(refs)
    allow(remote).to receive(:guarded_delete_if_matches!)

    expect(described_class.call(coworker:, remote:, now:)).to eq(0)
    expect(remote).not_to have_received(:guarded_delete_if_matches!)
  end

  it "is idempotent when an eligible ref disappeared concurrently" do
    ref = { branch: "coworkers/run/#{coworker.id}-99998", sha: "c" * 40, committed_at: now - 30.days }
    allow(remote).to receive(:merged_run_refs).and_return([ ref ])
    allow(remote).to receive(:guarded_delete_if_matches!).and_raise(Coworkers::RemoteWorkspace::RefChanged)

    expect(described_class.call(coworker:, remote:, now:)).to eq(0)
  end
end
