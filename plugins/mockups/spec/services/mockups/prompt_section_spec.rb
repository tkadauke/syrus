require "rails_helper"

RSpec.describe Mockups::PromptSection do
  let(:repo) { Factories.repository }
  let(:chat) { ChatSession.create!(repository: repo, user: repo.user) }

  it "points the agent at preview panels for mockups" do
    section = described_class.chat_prompt_section(chat_session: chat, repository: repo)

    expect(section).to include("show_preview", "write_preview_file", "edit_preview_file")
    expect(section).to include("UI mockups", "HTML mockups", "prototypes")
    expect(section).to include("screenshot-driven interface redesigns", "\"open the preview\"")
    expect(section).to include("HTML/UI mockups in Syrus Chat are not imagegen tasks")
    expect(section).to include("preview panels win for interface mockups")
    expect(section).to include("Do not use a local HTTP server, local file path, or workspace-only HTML")
    expect(section).to include("deferred or not currently loaded")
    expect(section).to include("Only tell the operator a preview is visible after the publish")
    expect(section).to include("`panel_id`, `version_id`, and `mockup_slug`")
  end

  it "reaches the chat system prompt through the injection point" do
    expect(Prompts::ChatSystem.new(repository: repo, chat_session: chat).to_s)
      .to include("use Syrus preview-panel tools by default")
  end
end
