require "rails_helper"

RSpec.describe ChatMediaLibrary do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:png_bytes) { "\x89PNG\r\n\x1a\n".b }

  describe ".materialize_inline_images!" do
    it "ignores legacy image metadata without inline data" do
      chat_session.messages.create!(
        role: "user",
        content: { "text" => "Missing image", "attachments" => [ { "name" => "missing.png", "mime_type" => "image/png" } ] }
      )

      expect {
        described_class.materialize_inline_images!(chat_session)
      }.not_to change(Document, :count)
    end

    it "materializes image attachments shared by the assistant" do
      attachment = chat_session.chat_file_attachments.build(
        name: "diagnosis.png",
        mime_type: "image/png",
        byte_size: png_bytes.bytesize,
        checksum: "pending"
      )
      attachment.file.attach(io: StringIO.new(png_bytes), filename: "diagnosis.png", content_type: "image/png")
      attachment.save!
      chat_session.messages.create!(
        role: "assistant",
        content: { "text" => "Here is the diagnosis.", "attachments" => [ { "id" => attachment.id } ] }
      )

      expect {
        described_class.materialize_inline_images!(chat_session)
      }.to change(Document, :count).by(1)

      document = chat_session.reload.attached_repository_documents.sole
      expect(document).to have_attributes(filename: "diagnosis.png", content_type: "image/png")
      expect(document.file.download).to eq(png_bytes)
    end
  end

  describe ".materialize_captured_image!" do
    it "creates a Document attached to the chat session's user" do
      document = described_class.materialize_captured_image!(
        chat_session,
        bytes: png_bytes,
        content_type: "image/png",
        title: "Screenshot"
      )

      expect(document).to be_a(Document)
      expect(document.attachable).to eq(user)
      expect(document.content_type).to eq("image/png")
      expect(document.byte_size).to eq(png_bytes.bytesize)
      expect(document.file).to be_attached
      expect(document.file.download).to eq(png_bytes)
    end

    it "attaches the document to the chat session" do
      document = described_class.materialize_captured_image!(
        chat_session,
        bytes: png_bytes,
        content_type: "image/png",
        title: "Screenshot"
      )

      expect(chat_session.chat_attachments.reload.map(&:attachable)).to include(document)
    end

    it "broadcasts a media update for open chat views" do
      expect(AppEvents).to receive(:broadcast_chat_resource).with(
        chat_session_id: chat_session.id,
        type: "updated",
        resource: "chat",
        id: chat_session.id,
        changed: [ "media" ]
      )

      described_class.materialize_captured_image!(
        chat_session,
        bytes: png_bytes,
        content_type: "image/png",
        title: "Screenshot"
      )
    end

    it "gives the document a filename derived from the title" do
      document = described_class.materialize_captured_image!(
        chat_session,
        bytes: png_bytes,
        content_type: "image/png",
        title: "browser_screenshot capture"
      )

      expect(document.filename).to eq("browser_screenshot-capture.png")
    end

    it "assigns a distinct source_url per call so repeat captures don't collide" do
      first = described_class.materialize_captured_image!(
        chat_session, bytes: png_bytes, content_type: "image/png", title: "Screenshot"
      )
      second = described_class.materialize_captured_image!(
        chat_session, bytes: png_bytes, content_type: "image/png", title: "Screenshot"
      )

      expect(first.source_url).not_to eq(second.source_url)
      expect(Document.count).to eq(2)
    end
  end
end
