require "rails_helper"

RSpec.describe ChatMediaLibrary do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:png_bytes) { "\x89PNG\r\n\x1a\n".b }

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
