require "rails_helper"

RSpec.describe PreviewPanel, type: :model do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def build_panel(**attrs)
    described_class.new({ chat_session: chat_session, title: "Widget preview" }.merge(attrs))
  end

  def create_panel(**attrs)
    described_class.create!({ chat_session: chat_session, title: "Widget preview" }.merge(attrs))
  end

  describe "validations" do
    it "is valid with required attributes" do
      expect(build_panel).to be_valid
    end

    it "requires a chat session" do
      expect(build_panel(chat_session: nil)).not_to be_valid
    end

    it "requires a title" do
      expect(build_panel(title: nil)).not_to be_valid
    end

    it "defaults to the open state" do
      expect(create_panel.state).to eq("open")
    end

    it "rejects unknown states" do
      expect(build_panel(state: "unknown")).not_to be_valid
    end

    it "accepts all defined states" do
      described_class::STATES.each do |state|
        panel = build_panel(state: state)
        panel.validate
        expect(panel.errors[:state]).to be_empty
      end
    end
  end

  describe "#open? / #closed?" do
    it "reflects the open state" do
      panel = create_panel(state: "open")
      expect(panel.open?).to be true
      expect(panel.closed?).to be false
    end

    it "reflects the closed state" do
      panel = create_panel(state: "closed")
      expect(panel.closed?).to be true
      expect(panel.open?).to be false
    end
  end

  describe "#preview_url" do
    it "derives a preview-panel- prefixed subdomain URL, defaulting to http" do
      panel = create_panel
      expect(panel.preview_url("syrus.example.com")).to eq("http://preview-panel-#{panel.id}.syrus.example.com")
    end

    it "uses the given scheme" do
      panel = create_panel
      expect(panel.preview_url("syrus.example.com", scheme: "https")).to eq("https://preview-panel-#{panel.id}.syrus.example.com")
    end
  end

  describe "#replace_files! and #file_for" do
    it "attaches files by relative filename" do
      panel = create_panel
      panel.replace_files!("index.html" => "<h1>hi</h1>", "css/app.css" => "body { color: red; }")

      expect(panel.file_for("index.html").blob.metadata["relative_path"]).to eq("index.html")
      expect(panel.file_for("css/app.css").blob.metadata["relative_path"]).to eq("css/app.css")
    end

    it "resolves a blank or root path to index.html" do
      panel = create_panel
      panel.replace_files!("index.html" => "<h1>hi</h1>")

      expect(panel.file_for("/").blob.metadata["relative_path"]).to eq("index.html")
      expect(panel.file_for("").blob.metadata["relative_path"]).to eq("index.html")
    end

    it "returns nil for a path with no matching attachment" do
      panel = create_panel
      panel.replace_files!("index.html" => "<h1>hi</h1>")

      expect(panel.file_for("missing.js")).to be_nil
    end

    it "purges the previous file set before attaching the new one" do
      panel = create_panel
      panel.replace_files!("index.html" => "<h1>v1</h1>", "old.js" => "console.log('old')")
      panel.replace_files!("index.html" => "<h1>v2</h1>")

      expect(panel.files.reload.map { |f| f.blob.filename.to_s }).to eq([ "index.html" ])
      expect(panel.file_for("index.html").download).to eq("<h1>v2</h1>")
    end

    it "accepts IO-like content in addition to strings" do
      panel = create_panel
      panel.replace_files!("index.html" => StringIO.new("<h1>from io</h1>"))

      expect(panel.file_for("index.html").download).to eq("<h1>from io</h1>")
    end
  end

  describe "#broadcast_change!" do
    it "broadcasts an app event for the React chat renderer" do
      panel = create_panel(title: "Widget preview")

      expect(AppEvents).to receive(:broadcast).with(
        user: user,
        type: "updated",
        resource: "chat",
        id: chat_session.id,
        changed: [ "preview_panels" ],
        payload: { "id" => panel.id, "title" => "Widget preview", "state" => "open", "file_count" => 0 }
      )

      panel.broadcast_change!
    end
  end

  it "is destroyed with its chat session" do
    panel = create_panel

    expect { chat_session.destroy }.to change { described_class.where(id: panel.id).count }.by(-1)
  end
end
