require "rails_helper"

RSpec.describe Coworkers::WorkspaceFileReadPolicy do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:scope) { Syrus::EffectScope.new(label: "coworker file read policy spec") }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      @root.join(".git").mkpath
      example.run
    end
  end

  before do
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(@root)
  end

  after { scope.dispose }

  %w[memory/daily/2026-10-01.md memory/banks/reflections.md].each do |relative_path|
    it "caps an on-demand read of #{relative_path}" do
      path = @root.join(relative_path)
      path.dirname.mkpath
      path.binwrite("x" * (described_class::MAX_BYTES + 1))

      result = ChatWorkspace.file_content(chat, repository, relative_path)

      expect(result).to include(binary: false, too_large: false, truncated: true)
      expect(result[:content].bytesize).to eq(described_class::MAX_BYTES)
      expect(result[:content]).to end_with("\n\n#{described_class::TRUNCATION_MARKER}\n")
    end
  end

  it "leaves non-memory workspace files on the ordinary workspace limit" do
    @root.join("notes.md").binwrite("x" * (described_class::MAX_BYTES + 1))

    result = ChatWorkspace.file_content(chat, repository, "notes.md")

    expect(result).to include(binary: false, too_large: false)
    expect(result).not_to have_key(:truncated)
    expect(result[:content].bytesize).to eq(described_class::MAX_BYTES + 1)
  end
end
