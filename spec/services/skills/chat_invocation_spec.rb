require "rails_helper"

RSpec.describe Skills::ChatInvocation do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:chat) { ChatSession.create!(repository: repository, user: user) }
  let(:client) { instance_double(GithubClient) }

  def enable_coding_mode!(enabled: true)
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: enabled)
  end

  def skill_md(name:, description: "Does a thing.")
    <<~MARKDOWN
      ---
      name: #{name}
      description: #{description}
      parameters:
        - key: question
          type: string
          required: true
      ---
      Repo-local instructions for #{name}: {{question}}
    MARKDOWN
  end

  before do
    allow(client).to receive(:file_content_at).and_return(nil)
  end

  def resolve(text:)
    described_class.resolve(chat_session: chat, text: text, client: client)
  end

  describe "#resolve" do
    it "returns not_a_command for ordinary chat text" do
      result = resolve(text: "what does this repo do?")

      expect(result.status).to eq(:not_a_command)
    end

    it "returns not_a_command when the chat has no attached repository" do
      unattached_chat = ChatSession.create!(user: user)

      result = described_class.resolve(chat_session: unattached_chat, text: "/investigate question=why?", client: client)

      expect(result.status).to eq(:not_a_command)
    end

    it "returns unknown_skill for a command name that resolves to nothing" do
      result = resolve(text: "/does-not-exist foo=bar")

      expect(result.status).to eq(:unknown_skill)
      expect(result.message).to include("/does-not-exist")
      expect(result.message).to include(repository.slug)
    end

    it "resolves to the built-in skill when there is no repo-local override" do
      enable_coding_mode!
      chat.update!(mode: "coding")

      result = resolve(text: '/investigate question="why is CI red?"')

      expect(result.status).to eq(:ready)
      expect(result.resolution.source).to eq(:built_in)
      expect(result.resolution.definition.name).to eq("investigate")
      expect(result.args).to eq("question" => "why is CI red?")
    end

    it "resolves to the repo-local skill, shadowing a built-in of the same name" do
      enable_coding_mode!
      chat.update!(mode: "coding")
      allow(client).to receive(:file_content_at)
        .with("acme/widgets", ".syrus/skills/investigate/SKILL.md", "main")
        .and_return(content: skill_md(name: "investigate", description: "Repo override."), size: 40)

      result = resolve(text: "/investigate question=why?")

      expect(result.status).to eq(:ready)
      expect(result.resolution.source).to eq(:repo_override)
      expect(result.resolution.path).to eq(".syrus/skills/investigate/SKILL.md")
      expect(result.resolution.definition.description).to eq("Repo override.")
    end

    it "returns invalid_args when a required parameter is missing" do
      enable_coding_mode!
      chat.update!(mode: "coding")

      result = resolve(text: "/investigate")

      expect(result.status).to eq(:invalid_args)
      expect(result.message).to include("question")
    end

    it "returns coding_mode_required with a clear message when Coding Mode is disabled" do
      enable_coding_mode!(enabled: false)

      result = resolve(text: "/investigate question=why?")

      expect(result.status).to eq(:coding_mode_required)
      expect(result.message).to include("Coding Mode")
      expect(result.resolution).not_to be_nil
    end

    it "returns coding_mode_required when the chat is in planning mode even though the flag is on" do
      enable_coding_mode!(enabled: true)
      chat.update!(mode: "planning")

      result = resolve(text: "/investigate question=why?")

      expect(result.status).to eq(:coding_mode_required)
    end
  end
end
