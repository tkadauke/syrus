require "rails_helper"

RSpec.describe WhiteboardTools::PromptSection do
  let(:repo) { Factories.repository }
  let(:chat) { ChatSession.create!(repository: repo, user: repo.user) }

  it "describes the high-level drawing tools rather than raw Excalidraw JSON" do
    section = described_class.chat_prompt_section(chat_session: chat, repository: repo)

    expect(section).to include("draw_shape", "draw_text", "read_scene", "save_canvas")
    expect(section).to include("over raw Excalidraw JSON")
  end

  it "reaches the chat system prompt through the injection point" do
    expect(Prompts::ChatSystem.new(repository: repo, chat_session: chat).to_s)
      .to include("You have access to a shared whiteboard alongside this chat")
  end
end
