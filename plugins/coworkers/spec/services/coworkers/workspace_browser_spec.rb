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
    stub_repository_content(repository, ref: repository.default_branch, files: {})

    result = described_class.new(coworker: coworker, repository: repository, user: owner).call

    expect(result[:conflicts]).to be_empty
  end
end
