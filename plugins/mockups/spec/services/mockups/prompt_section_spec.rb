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
    expect(section).to include("`inspect_preview_versions`", "Do not reconstruct an old version from memory")
  end

  it "recommends render-and-inspect before publishing without making it a gate" do
    section = described_class.chat_prompt_section(chat_session: chat, repository: repo)

    flat = section.squish
    expect(flat).to include("Strongly recommended before publishing", "`render_preview`", "desktop and mobile")
    expect(flat).to include("bounded `wait_ms`", "guidance, not a gate")
    expect(section.index("`render_preview` and visually inspect")).to be < section.index("publish with `show_preview`")
  end

  it "mentions render-and-inspect in the publishing tool descriptions" do
    descriptions = Mockups::ChatToolSet.tool_definitions(tier: :essential).to_h { |tool| [ tool[:name], tool[:description] ] }

    expect(descriptions.fetch("show_preview")).to include("render_preview", "not a hard gate")
    expect(descriptions.fetch("write_preview_file")).to include("render_preview")
    expect(descriptions.fetch("render_preview")).to include("guidance, not a gate", "does not create a version")
  end

  it "reaches the chat system prompt through the injection point" do
    expect(Prompts::ChatSystem.new(repository: repo, chat_session: chat).to_s)
      .to include("use Syrus preview-panel tools by default")
  end
end
