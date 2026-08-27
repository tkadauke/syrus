require "rails_helper"

RSpec.describe ThemingTools::ChatToolSet do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:tool_set) { ThemingTools::ChatToolSet.new }

  def call_tool(name, arguments = {})
    tool_set.handle(name, arguments, { chat_session: chat_session })
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  def full_tokens(seed)
    Theme::TOKEN_KEYS.index_with { |key| "#{seed}-#{key}" }
  end

  describe ".available_for?" do
    it "is available at the deferred tier" do
      expect(described_class.available_for?(chat_session, tier: :deferred)).to be true
    end

    it "is unavailable at the essential tier" do
      expect(described_class.available_for?(chat_session, tier: :essential)).to be false
    end
  end

  describe ".tool_definitions" do
    it "exposes preview_theme" do
      names = described_class.tool_definitions(tier: :deferred).map { |tool| tool.fetch(:name) }

      expect(names).to contain_exactly("preview_theme")
    end
  end

  describe "#handle" do
    it "errors when there is no chat session in context" do
      response = tool_set.handle("preview_theme", { name: "Draft" }, {})

      expect(response.error?).to be true
      expect(response.content.first[:text]).to match(/No chat session/)
    end

    it "errors for an unknown tool name" do
      response = call_tool("delete_everything")

      expect(response.error?).to be true
      expect(response.content.first[:text]).to match(/Unknown theming tool/)
    end
  end

  describe "preview_theme" do
    def expect_preview_broadcast
      expect(AppEvents).to receive(:broadcast) do |**kwargs|
        expect(kwargs[:user]).to eq(user)
        expect(kwargs[:type]).to eq("updated")
        expect(kwargs[:resource]).to eq("chat")
        expect(kwargs[:id]).to eq(chat_session.id)
        expect(kwargs[:payload][:action]).to eq("open_theme_preview")
        expect(kwargs[:payload][:theme_id]).to be_a(Integer)
        expect(kwargs[:payload][:path]).to eq("/design_system?theme_id=#{kwargs[:payload][:theme_id]}")
      end
    end

    it "creates a non-built-in draft theme owned by the chat's user, defaulting all tokens to the active theme" do
      active = Factories.theme(slug: "terracotta", built_in: true, tokens: { "light" => full_tokens("active-light"), "dark" => full_tokens("active-dark") })
      user.update!(color_theme: active)

      response = nil
      expect {
        expect_preview_broadcast
        response = call_tool("preview_theme", name: "My Draft")
      }.to change(Theme, :count).by(1)

      theme = Theme.last
      expect(response.error?).to be_falsey
      expect(theme).to have_attributes(name: "My Draft", built_in: false, owner_user_id: user.id)
      expect(theme.tokens).to eq("light" => full_tokens("active-light"), "dark" => full_tokens("active-dark"))
      expect(payload(response)).to include(theme_id: theme.id, name: "My Draft")
    end

    it "applies partial overrides while defaulting the rest to the active theme" do
      active = Factories.theme(slug: "terracotta", built_in: true, tokens: { "light" => full_tokens("active-light"), "dark" => full_tokens("active-dark") })
      user.update!(color_theme: active)
      expect_preview_broadcast

      call_tool("preview_theme", name: "My Draft", light: { "brand" => "#123456" })

      theme = Theme.last
      expect(theme.tokens["light"]["brand"]).to eq("#123456")
      expect(theme.tokens["light"]["surface"]).to eq("active-light-surface")
      expect(theme.tokens["dark"]).to eq(full_tokens("active-dark"))
    end

    it "updates the same draft row in place on repeat calls instead of creating duplicates" do
      active = Factories.theme(slug: "terracotta", built_in: true, tokens: { "light" => full_tokens("active-light"), "dark" => full_tokens("active-dark") })
      user.update!(color_theme: active)
      allow(AppEvents).to receive(:broadcast)

      call_tool("preview_theme", name: "First pass", light: { "brand" => "#111111" })
      first_id = Theme.last.id

      response = nil
      expect {
        response = call_tool("preview_theme", name: "Second pass", light: { "brand" => "#222222" })
      }.not_to change(Theme, :count)

      theme = Theme.find(first_id)
      expect(response.error?).to be_falsey
      expect(theme.name).to eq("Second pass")
      expect(theme.tokens["light"]["brand"]).to eq("#222222")
    end

    it "keeps drafts separate per user" do
      active = Factories.theme(slug: "terracotta", built_in: true, tokens: { "light" => full_tokens("active-light"), "dark" => full_tokens("active-dark") })
      user.update!(color_theme: active)
      other_user = Factories.user(color_theme: active)
      other_chat_session = ChatSession.create!(user: other_user, repository: Factories.repository(user: other_user))
      allow(AppEvents).to receive(:broadcast)

      call_tool("preview_theme", name: "Mine")
      tool_set.handle("preview_theme", { name: "Theirs" }, { chat_session: other_chat_session })

      expect(Theme.where(built_in: false).count).to eq(2)
      expect(Theme.where(built_in: false, owner_user: user).count).to eq(1)
      expect(Theme.where(built_in: false, owner_user: other_user).count).to eq(1)
    end

    it "returns a validation error and broadcasts nothing when a token is still missing after defaulting" do
      expect(AppEvents).not_to receive(:broadcast)

      response = nil
      expect {
        response = call_tool("preview_theme", name: "No baseline", light: { "brand" => "#111111" })
      }.not_to change(Theme, :count)

      expect(response.error?).to be true
      expect(response.content.first[:text]).to match(/tokens/i)
    end
  end
end
