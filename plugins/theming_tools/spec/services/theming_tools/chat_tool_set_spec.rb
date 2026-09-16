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
    it "exposes preview_theme, install_theme, and theme CRUD" do
      names = described_class.tool_definitions(tier: :deferred).map { |tool| tool.fetch(:name) }

      expect(names).to contain_exactly(
        "preview_theme", "install_theme", "list_user_themes", "update_user_theme", "delete_user_theme"
      )
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

    it "surfaces a non-blocking contrast_warnings array and still saves when a draft has a real contrast issue" do
      active = Factories.theme(slug: "terracotta", built_in: true, tokens: legible_tokens)
      user.update!(color_theme: active)
      allow(AppEvents).to receive(:broadcast)

      response = call_tool("preview_theme", name: "Bad Draft", light: { "text-primary" => "#fefefe" })

      expect(response.error?).to be_falsey
      expect(Theme.last.persisted?).to be true
      warnings = payload(response)[:contrast_warnings]
      expect(warnings).not_to be_empty
      expect(warnings).to include(match(/light text-primary.*surface.*contrast/i))
    end

    it "returns an empty contrast_warnings array when the draft has no contrast issues" do
      active = Factories.theme(slug: "terracotta", built_in: true, tokens: legible_tokens)
      user.update!(color_theme: active)
      allow(AppEvents).to receive(:broadcast)

      response = call_tool("preview_theme", name: "Fine Draft")

      expect(response.error?).to be_falsey
      expect(payload(response)[:contrast_warnings]).to eq([])
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

    it "applies partial non-color (extended) token overrides while defaulting the rest to the active theme" do
      active = Factories.theme(
        slug: "terracotta", built_in: true,
        tokens: { "light" => full_tokens("active-light"), "dark" => full_tokens("active-dark"), "shape" => { "radius-control" => "1px", "radius-panel" => "2px" } }
      )
      user.update!(color_theme: active)
      allow(AppEvents).to receive(:broadcast)

      call_tool("preview_theme", name: "My Draft", shape: { "radius-control" => "0px" })

      theme = Theme.last
      expect(theme.tokens["shape"]).to eq("radius-control" => "0px", "radius-panel" => "2px")
      expect(theme.tokens).not_to have_key("shadow")
    end

    it "defaults every non-color group to Theme::DEFAULT_EXTENDED_TOKENS when the active theme never set any" do
      active = Factories.theme(slug: "terracotta", built_in: true, tokens: { "light" => full_tokens("active-light"), "dark" => full_tokens("active-dark") })
      user.update!(color_theme: active)
      allow(AppEvents).to receive(:broadcast)

      call_tool("preview_theme", name: "My Draft", typography: { "font-sans" => "monospace" })

      theme = Theme.last
      expect(theme.tokens["typography"]).to eq("font-sans" => "monospace")
      expect(theme.tokens_with_defaults["typography"]["text-body"]).to eq(Theme::DEFAULT_EXTENDED_TOKENS.fetch("typography").fetch("text-body"))
      expect(theme.tokens_with_defaults["shape"]).to eq(Theme::DEFAULT_EXTENDED_TOKENS.fetch("shape"))
    end
  end

  def legible_tokens
    {
      "light" => {
        "brand" => "#b6492e", "brand-emphasis" => "#973b25", "surface" => "#ffffff",
        "surface-raised" => "#f9fafb", "border" => "#e5e7eb", "text-primary" => "#111827",
        "text-secondary" => "#6b7280", "success" => "#047857", "warning" => "#b45309",
        "danger" => "#b91c1c", "info" => "#1d4ed8", "neutral" => "#374151", "on-brand" => "#ffffff"
      },
      "dark" => {
        "brand" => "#b6492e", "brand-emphasis" => "#dba28b", "surface" => "#111827",
        "surface-raised" => "#1f2937", "border" => "#374151", "text-primary" => "#f3f4f6",
        "text-secondary" => "#9ca3af", "success" => "#a7f3d0", "warning" => "#fde68a",
        "danger" => "#fecaca", "info" => "#bfdbfe", "neutral" => "#e5e7eb", "on-brand" => "#ffffff"
      }
    }
  end

  describe "install_theme" do
    it "installs an existing owned theme by theme_id and sets it as the user's active theme" do
      draft = Factories.theme(owner_user: user, built_in: false, tokens: legible_tokens, name: "Draft")

      response = call_tool("install_theme", theme_id: draft.id)

      expect(response.error?).to be_falsey
      expect(user.reload.color_theme_id).to eq(draft.id)
      expect(payload(response)).to include(id: draft.id, name: "Draft")
    end

    it "installs a built-in theme by theme_id too" do
      built_in = Factories.theme(built_in: true, tokens: legible_tokens, name: "Ocean")

      response = call_tool("install_theme", theme_id: built_in.id)

      expect(response.error?).to be_falsey
      expect(user.reload.color_theme_id).to eq(built_in.id)
    end

    it "creates and installs a new theme from a full token payload" do
      response = nil
      expect {
        response = call_tool("install_theme", name: "My New Theme", light: legible_tokens["light"], dark: legible_tokens["dark"])
      }.to change(Theme, :count).by(1)

      theme = Theme.last
      expect(response.error?).to be_falsey
      expect(theme).to have_attributes(name: "My New Theme", built_in: false, owner_user_id: user.id)
      expect(user.reload.color_theme_id).to eq(theme.id)
    end

    it "rejects an inaccessible theme_id without changing the user's active theme" do
      other_user = Factories.user
      theirs = Factories.theme(owner_user: other_user, built_in: false, tokens: legible_tokens)
      previous_theme_id = user.color_theme_id

      response = call_tool("install_theme", theme_id: theirs.id)

      expect(response.error?).to be true
      expect(user.reload.color_theme_id).to eq(previous_theme_id)
    end

    it "rejects a palette that fails the contrast check with a specific message, without installing it" do
      bad_theme = Factories.theme(owner_user: user, built_in: false)

      response = call_tool("install_theme", theme_id: bad_theme.id)

      expect(response.error?).to be true
      expect(response.content.first[:text]).to match(/contrast/i)
      expect(user.reload.color_theme_id).not_to eq(bad_theme.id)
    end

    it "rejects when neither theme_id nor a full payload is given" do
      response = call_tool("install_theme", name: "Incomplete")

      expect(response.error?).to be true
      expect(response.content.first[:text]).to match(/theme_id|light|dark/i)
    end

    it "creates and installs a new theme with partial non-color token overrides, defaulting the rest" do
      response = nil
      expect {
        response = call_tool(
          "install_theme", name: "Console-ish", light: legible_tokens["light"], dark: legible_tokens["dark"],
          shape: { "radius-control" => "0px" }, typography: { "font-sans" => "monospace" }
        )
      }.to change(Theme, :count).by(1)

      theme = Theme.last
      expect(response.error?).to be_falsey
      expect(theme.tokens["shape"]).to eq("radius-control" => "0px")
      expect(theme.tokens).not_to have_key("density")

      result = payload(response)
      expect(result[:tokens][:shape][:"radius-control"]).to eq("0px")
      expect(result[:tokens][:shape][:"radius-panel"]).to eq(Theme::DEFAULT_EXTENDED_TOKENS.fetch("shape").fetch("radius-panel"))
      expect(result[:tokens][:density]).to eq(Theme::DEFAULT_EXTENDED_TOKENS.fetch("density").symbolize_keys)
    end
  end

  describe "list_user_themes" do
    it "returns only the current user's own non-built-in themes" do
      Factories.theme(built_in: true)
      mine = Factories.theme(owner_user: user, built_in: false, tokens: legible_tokens, name: "Mine")
      Factories.theme(owner_user: Factories.user, built_in: false, tokens: legible_tokens)

      response = call_tool("list_user_themes")

      expect(response.error?).to be_falsey
      expect(payload(response)[:themes]).to contain_exactly(JSON.parse(JSON.generate(mine.public_payload), symbolize_names: true))
    end

    it "includes fully-defaulted non-color token groups for a theme that only overrode some of them" do
      Factories.theme(
        owner_user: user, built_in: false, name: "Partial",
        tokens: legible_tokens.merge("density" => { "control-height-sm" => "1.5rem" })
      )

      response = call_tool("list_user_themes")

      theme_payload = payload(response)[:themes].first
      expect(theme_payload[:tokens][:density][:"control-height-sm"]).to eq("1.5rem")
      expect(theme_payload[:tokens][:density][:"control-height-md"]).to eq(Theme::DEFAULT_EXTENDED_TOKENS.fetch("density").fetch("control-height-md"))
      expect(theme_payload[:tokens][:shape]).to eq(Theme::DEFAULT_EXTENDED_TOKENS.fetch("shape").symbolize_keys)
    end
  end

  describe "update_user_theme" do
    it "renames and applies partial token overrides, keeping omitted tokens" do
      theme = Factories.theme(owner_user: user, built_in: false, tokens: legible_tokens, name: "Old Name")

      response = call_tool("update_user_theme", theme_id: theme.id, name: "New Name", light: { "brand" => "#123456" })

      expect(response.error?).to be_falsey
      theme.reload
      expect(theme.name).to eq("New Name")
      expect(theme.tokens["light"]["brand"]).to eq("#123456")
      expect(theme.tokens["light"]["surface"]).to eq(legible_tokens["light"]["surface"])
    end

    it "rejects an update that would fail the contrast check, leaving the theme unchanged" do
      theme = Factories.theme(owner_user: user, built_in: false, tokens: legible_tokens, name: "Old Name")

      response = call_tool("update_user_theme", theme_id: theme.id, light: { "text-secondary" => "#fefefe" })

      expect(response.error?).to be true
      expect(response.content.first[:text]).to match(/contrast/i)
      expect(theme.reload.tokens["light"]["text-secondary"]).to eq(legible_tokens["light"]["text-secondary"])
    end

    it "refuses to update a built-in theme" do
      built_in = Factories.theme(built_in: true, tokens: legible_tokens)

      response = call_tool("update_user_theme", theme_id: built_in.id, name: "Hijacked")

      expect(response.error?).to be true
    end

    it "refuses to update another user's theme" do
      theirs = Factories.theme(owner_user: Factories.user, built_in: false, tokens: legible_tokens)

      response = call_tool("update_user_theme", theme_id: theirs.id, name: "Hijacked")

      expect(response.error?).to be true
    end

    it "applies partial non-color token overrides while keeping other stored groups and keys untouched" do
      theme = Factories.theme(
        owner_user: user, built_in: false, name: "Old Name",
        tokens: legible_tokens.merge("shape" => { "radius-control" => "1px", "radius-panel" => "2px" })
      )

      response = call_tool("update_user_theme", theme_id: theme.id, shape: { "radius-control" => "0px" }, density: { "control-height-sm" => "1.5rem" })

      expect(response.error?).to be_falsey
      theme.reload
      expect(theme.tokens["shape"]).to eq("radius-control" => "0px", "radius-panel" => "2px")
      expect(theme.tokens["density"]).to eq("control-height-sm" => "1.5rem")
    end
  end

  describe "delete_user_theme" do
    it "deletes a custom theme that isn't the user's active theme" do
      other_active = Factories.theme(built_in: true, tokens: legible_tokens)
      user.update!(color_theme: other_active)
      theme = Factories.theme(owner_user: user, built_in: false, tokens: legible_tokens)

      response = call_tool("delete_user_theme", theme_id: theme.id)

      expect(response.error?).to be_falsey
      expect(Theme.exists?(theme.id)).to be false
      expect(user.reload.color_theme_id).to eq(other_active.id)
    end

    it "falls back to the default built-in theme when deleting the user's active theme" do
      terracotta = Factories.theme(slug: "terracotta", built_in: true, tokens: legible_tokens)
      theme = Factories.theme(owner_user: user, built_in: false, tokens: legible_tokens)
      user.update!(color_theme: theme)

      response = call_tool("delete_user_theme", theme_id: theme.id)

      expect(response.error?).to be_falsey
      expect(payload(response)).to include(fallback_theme_id: terracotta.id)
      expect(user.reload.color_theme_id).to eq(terracotta.id)
    end

    it "refuses to delete a built-in theme" do
      built_in = Factories.theme(built_in: true, tokens: legible_tokens)

      response = call_tool("delete_user_theme", theme_id: built_in.id)

      expect(response.error?).to be true
      expect(Theme.exists?(built_in.id)).to be true
    end

    it "refuses to delete another user's theme" do
      theirs = Factories.theme(owner_user: Factories.user, built_in: false, tokens: legible_tokens)

      response = call_tool("delete_user_theme", theme_id: theirs.id)

      expect(response.error?).to be true
      expect(Theme.exists?(theirs.id)).to be true
    end

    it "deletes a custom theme that has non-color token overrides just as it would a color-only theme" do
      other_active = Factories.theme(built_in: true, tokens: legible_tokens)
      user.update!(color_theme: other_active)
      theme = Factories.theme(owner_user: user, built_in: false, tokens: legible_tokens.merge("typography" => { "font-sans" => "monospace" }))

      response = call_tool("delete_user_theme", theme_id: theme.id)

      expect(response.error?).to be_falsey
      expect(Theme.exists?(theme.id)).to be false
    end
  end
end
