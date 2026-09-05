require "rails_helper"

RSpec.describe Mockups::PromptSection do
  let(:repo) { Factories.repository }
  let(:chat) { ChatSession.create!(repository: repo, user: repo.user) }

  it "points the agent at preview panels for mockups" do
    section = described_class.chat_prompt_section(chat_session: chat, repository: repo)

    expect(section).to include("show_preview", "write_preview_file", "edit_preview_file")
  end

  it "reaches the chat system prompt through the injection point" do
    expect(Prompts::ChatSystem.new(repository: repo, chat_session: chat).to_s)
      .to include("prefer Syrus preview-panel")
  end
end
