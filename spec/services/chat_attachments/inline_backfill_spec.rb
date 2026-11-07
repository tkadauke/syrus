require "rails_helper"

RSpec.describe ChatAttachments::InlineBackfill do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }
  let(:bytes) { "stored attachment bytes" }

  it "stores and verifies attachment bytes before replacing inline data with a reference" do
    message = chat.messages.create!(
      role: "user",
      content: {
        "text" => "Inspect this",
        "attachments" => [
          { "name" => "notes.txt", "mime_type" => "text/plain", "data" => Base64.strict_encode64(bytes) }
        ]
      }
    )

    expect(described_class.new(message).call).to eq(1)

    attachment = message.reload.chat_file_attachments.sole
    expect(attachment.file.download).to eq(bytes)
    expect(attachment).to have_attributes(byte_size: bytes.bytesize, checksum: Digest::MD5.base64digest(bytes))
    expect(message.content.fetch("attachments")).to contain_exactly(
      "id" => attachment.id,
      "name" => "notes.txt",
      "mime_type" => "text/plain",
      "size" => bytes.bytesize
    )
  end

  it "leaves malformed inline data untouched" do
    queued = chat.queued_messages.create!(
      content: { "text" => "Broken", "attachments" => [ { "name" => "bad.txt", "mime_type" => "text/plain", "data" => "%%%" } ] }
    )

    expect { described_class.new(queued).call }
      .to raise_error(described_class::InvalidAttachment, /malformed base64/)

    expect(queued.reload.content.dig("attachments", 0, "data")).to(
      eq("%%%").and(be_present)
    )
    expect(queued.chat_file_attachments).to be_empty
  end

  it "keeps inline data when the stored bytes fail verification" do
    message = chat.messages.create!(
      role: "user",
      content: {
        "text" => "Inspect this",
        "attachments" => [
          { "name" => "notes.txt", "mime_type" => "text/plain", "data" => Base64.strict_encode64(bytes) }
        ]
      }
    )
    allow_any_instance_of(ActiveStorage::Blob).to receive(:download).and_return("different bytes")

    expect { described_class.new(message).call }
      .to raise_error(described_class::InvalidAttachment, /failed byte size\/checksum verification/)

    expect(message.reload.content.dig("attachments", 0, "data")).to eq(Base64.strict_encode64(bytes))
    expect(message.chat_file_attachments).to be_empty
  end

  it "rewrites JSON-backed scratchpad content" do
    item = chat.scratchpad_items.create!(
      content: JSON.generate("text" => "Draft", "attachments" => [ { "name" => "draft.txt", "mime_type" => "text/plain", "data" => Base64.strict_encode64(bytes) } ]),
      position: 0
    )

    described_class.new(item).call

    content = JSON.parse(item.reload.content)
    expect(content.dig("attachments", 0, "data")).to be_nil
    expect(content.dig("attachments", 0, "id")).to eq(item.chat_file_attachments.sole.id)
  end
end
