require "rails_helper"

RSpec.describe PersonalDocuments::Origin do
  def origin_for(source_url, chats_by_id: {})
    described_class.for(Struct.new(:source_url).new(source_url), chats_by_id:).as_json
  end

  it "classifies manual and legacy documents as personal context" do
    expect(origin_for(nil)).to eq(kind: "personal", chat: nil)
    expect(origin_for("https://docs.google.com/document/d/example/edit")).to eq(kind: "personal", chat: nil)
  end

  it "classifies and links chat uploads and runtime captures" do
    upload_chat = Struct.new(:id).new(17)
    capture_chat = Struct.new(:id).new(23)

    expect(origin_for("chat-message-image://17/123/0", chats_by_id: { 17 => upload_chat })).to eq(
      kind: "chat_upload", chat: { id: 17, label: "CHAT-17", path: "/chats/17" }
    )
    expect(origin_for("chat-captured-image://23/456/0", chats_by_id: { 23 => capture_chat })).to eq(
      kind: "chat_capture", chat: { id: 23, label: "CHAT-23", path: "/chats/23" }
    )
  end

  it "preserves chat provenance when the chat cannot be resolved" do
    expect(origin_for("chat-message-image://99/123/0")).to eq(kind: "chat_upload", chat: nil)
    expect(origin_for("chat-captured-image://99/456/0")).to eq(kind: "chat_capture", chat: nil)
  end
end
