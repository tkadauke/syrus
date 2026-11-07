require "rails_helper"

RSpec.describe ChatDraftContent, type: :model do
  describe ".from_content" do
    it "falls back to legacy content when text is blank" do
      draft = described_class.from_content({ "text" => "", "content" => "actual body" })

      expect(draft.text).to eq("actual body")
    end
  end

  describe ".from_record" do
    it "returns a stored attachment reference without inline data" do
      user = Factories.user
      chat = ChatSession.create!(user: user)
      attachment = chat.chat_file_attachments.build(name: "notes.txt", mime_type: "text/plain", byte_size: 5, checksum: "pending")
      attachment.file.attach(io: StringIO.new("hello"), filename: "notes.txt", content_type: "text/plain")
      attachment.save!
      queued_message = chat.queued_messages.create!(content: { "text" => "", "attachments" => [ { "id" => attachment.id } ] })

      payload = described_class.from_record(queued_message).attachments.sole

      expect(payload).to include("id" => attachment.id, "url" => "/api/v1/app/chats/#{chat.id}/attachments/#{attachment.id}/file")
      expect(payload).not_to have_key("data")
    end
  end
end
