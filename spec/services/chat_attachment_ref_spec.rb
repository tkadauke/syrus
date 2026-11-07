require "rails_helper"

RSpec.describe ChatAttachmentRef do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }

  it "reads legacy inline attachment bytes and metadata" do
    message = chat.messages.create!(role: "user", content: { "text" => "", "attachments" => [
      { "name" => "notes.txt", "mime_type" => "text/plain", "data" => Base64.strict_encode64("hello") }
    ] }, sender_user: user)

    ref = described_class.for(message).sole

    expect(ref.bytes).to eq("hello")
    expect(ref.payload).to eq("name" => "notes.txt", "mime_type" => "text/plain", "data" => Base64.strict_encode64("hello"))
  end

  it "reads a storage-backed attachment and claims it for its message" do
    attachment = chat.chat_file_attachments.build(name: "diagram.png", mime_type: "image/png", byte_size: 3, checksum: "pending")
    attachment.file.attach(io: StringIO.new("png"), filename: "diagram.png", content_type: "image/png")
    attachment.save!
    message = chat.messages.create!(role: "user", content: { "text" => "", "attachments" => [ { "id" => attachment.id } ] }, sender_user: user)

    ref = described_class.for(message).sole

    expect(ref.bytes).to eq("png")
    expect(ref.payload).to include("id" => attachment.id, "url" => "/api/v1/app/chats/#{chat.id}/attachments/#{attachment.id}/file")
    expect(attachment.reload.attachable).to eq(message)
  end
end
