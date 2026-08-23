require "rails_helper"

RSpec.describe PreviewPanel::Service do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  describe ".open!" do
    it "creates an open panel with the given title and files" do
      panel = described_class.open!(
        chat_session: chat_session,
        title: "Widget preview",
        files: { "index.html" => "<h1>hi</h1>" }
      )

      expect(panel).to be_a(PreviewPanel)
      expect(panel).to be_persisted
      expect(panel.chat_session).to eq(chat_session)
      expect(panel.title).to eq("Widget preview")
      expect(panel.state).to eq("open")
      expect(panel.file_for("index.html").download).to eq("<h1>hi</h1>")
    end

    it "broadcasts a live update" do
      expect(AppEvents).to receive(:broadcast).with(hash_including(changed: [ "preview_panels" ]))

      described_class.open!(chat_session: chat_session, title: "Widget preview", files: {})
    end

    it "defaults files to an empty set when omitted" do
      panel = described_class.open!(chat_session: chat_session, title: "Widget preview")

      expect(panel.files).to be_empty
    end
  end

  describe "#update!" do
    it "replaces the panel's attached files" do
      panel = described_class.open!(
        chat_session: chat_session,
        title: "Widget preview",
        files: { "index.html" => "<h1>v1</h1>" }
      )

      described_class.new(panel).update!(files: { "index.html" => "<h1>v2</h1>" })

      expect(panel.file_for("index.html").download).to eq("<h1>v2</h1>")
    end

    it "broadcasts a live update" do
      panel = described_class.open!(chat_session: chat_session, title: "Widget preview", files: {})

      expect(AppEvents).to receive(:broadcast).with(hash_including(changed: [ "preview_panels" ]))

      described_class.new(panel).update!(files: { "index.html" => "<h1>hi</h1>" })
    end

    it "does not change the panel's state" do
      panel = described_class.open!(chat_session: chat_session, title: "Widget preview", files: {})

      described_class.new(panel).update!(files: {})

      expect(panel.reload.state).to eq("open")
    end
  end

  describe "#close!" do
    it "transitions the panel to closed" do
      panel = described_class.open!(chat_session: chat_session, title: "Widget preview", files: {})

      described_class.new(panel).close!

      expect(panel.reload.state).to eq("closed")
    end

    it "broadcasts a live update" do
      panel = described_class.open!(chat_session: chat_session, title: "Widget preview", files: {})

      expect(AppEvents).to receive(:broadcast).with(hash_including(changed: [ "preview_panels" ]))

      described_class.new(panel).close!
    end
  end
end
