require "rails_helper"

RSpec.describe Coworkers::PromptSection do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:scope) { Syrus::EffectScope.new(label: "coworker prompt spec") }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  before do
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(@root)
  end

  after { scope.dispose }

  it "loads the three identity files under the cap into fresh and resumed prompts" do
    described_class::FILES.each { |name| @root.join(name).write("content from #{name}\n") }
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_prompt_injector).and_return([ described_class ])

    fresh = Prompts::ChatSystem.new(repository: repository, chat_session: chat).to_s
    resumed = Prompts::ChatSystem.new(repository: repository, chat_session: chat).elaboration_guidance

    described_class::FILES.each do |name|
      expect(fresh).to include(name, "content from #{name}")
      expect(resumed).to include(name, "content from #{name}")
    end
  end

  it "caps individual and total identity content" do
    described_class::FILES.each { |name| @root.join(name).binwrite("x" * described_class::MAX_FILE_BYTES) }

    section = described_class.chat_prompt_section(chat_session: chat, repository: repository)

    expect(section.bytesize).to be <= described_class::MAX_TOTAL_BYTES + 200
  end
end
