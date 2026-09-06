require "rails_helper"

RSpec.describe ChatMediaLibrary do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:chat) { ChatSession.create!(user: user) }

  def create_message!(role:, attachments: nil, text: "hi")
    content = { "text" => text }
    content["attachments"] = attachments if attachments
    chat.messages.create!(role: role, content: content)
  end

  def image_attachment(name: "shot.png", data: Base64.strict_encode64("bytes"))
    { "name" => name, "mime_type" => "image/png", "data" => data }
  end

  describe ".any_inline_images?" do
    it "is false for a chat with no messages" do
      expect(described_class.any_inline_images?(chat)).to be(false)
    end

    it "is false for a chat whose messages have no attachments" do
      create_message!(role: "user")
      create_message!(role: "assistant")

      expect(described_class.any_inline_images?(chat)).to be(false)
    end

    it "is false for a non-image attachment" do
      create_message!(role: "user", attachments: [ { "name" => "notes.pdf", "mime_type" => "application/pdf", "data" => "abc" } ])

      expect(described_class.any_inline_images?(chat)).to be(false)
    end

    it "is false for an image attachment with no data" do
      create_message!(role: "user", attachments: [ { "name" => "shot.png", "mime_type" => "image/png", "data" => "" } ])

      expect(described_class.any_inline_images?(chat)).to be(false)
    end

    it "is true for a user message with an image attachment" do
      create_message!(role: "user", attachments: [ image_attachment ])

      expect(described_class.any_inline_images?(chat)).to be(true)
    end

    it "ignores an image attachment on a non-user message (assistant messages never carry uploaded attachments)" do
      create_message!(role: "assistant", attachments: [ image_attachment ])

      expect(described_class.any_inline_images?(chat)).to be(false)
    end

    it "finds an image attachment outside the first existence-check batch" do
      # Regression guard for the batched scan: stub a tiny batch size so a
      # match beyond the first batch only turns up true if the scan keeps
      # going to the next batch instead of stopping after the first.
      stub_const("ChatMediaLibrary::EXISTENCE_CHECK_BATCH_SIZE", 1)
      create_message!(role: "user", text: "no image here")
      create_message!(role: "user", attachments: [ image_attachment ])

      expect(described_class.any_inline_images?(chat)).to be(true)
    end
  end

  describe ".materialize_inline_images!" do
    it "attaches a persisted Document for each inline image attachment and is idempotent" do
      create_message!(role: "user", attachments: [ image_attachment ])

      expect { described_class.materialize_inline_images!(chat) }.to change { chat.chat_attachments.count }.by(1)

      # Calling it again must not create a duplicate attachment/document.
      expect { described_class.materialize_inline_images!(chat) }.not_to(change { chat.chat_attachments.count })
    end

    it "does not materialize a non-image attachment" do
      create_message!(role: "user", attachments: [ { "name" => "notes.pdf", "mime_type" => "application/pdf", "data" => "abc" } ])

      expect { described_class.materialize_inline_images!(chat) }.not_to(change { chat.chat_attachments.count })
    end
  end
end
