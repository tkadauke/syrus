require "rails_helper"

RSpec.describe PreviewPanelVersion, type: :model do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:panel) { PreviewPanel.create!(chat_session: chat_session, title: "Widget preview") }

  describe "#file_for" do
    it "attaches files by relative filename" do
      version = panel.create_version!("index.html" => "<h1>hi</h1>", "css/app.css" => "body { color: red; }")

      expect(version.file_for("index.html").blob.metadata["relative_path"]).to eq("index.html")
      expect(version.file_for("css/app.css").blob.metadata["relative_path"]).to eq("css/app.css")
    end

    it "resolves a blank or root path to index.html" do
      version = panel.create_version!("index.html" => "<h1>hi</h1>")

      expect(version.file_for("/").blob.metadata["relative_path"]).to eq("index.html")
      expect(version.file_for("").blob.metadata["relative_path"]).to eq("index.html")
    end

    it "returns nil for a path with no matching attachment" do
      version = panel.create_version!("index.html" => "<h1>hi</h1>")

      expect(version.file_for("missing.js")).to be_nil
    end
  end

  describe "ordering" do
    it "orders newest-first by default" do
      first_version = panel.preview_panel_versions.create!(created_at: 2.hours.ago)
      second_version = panel.preview_panel_versions.create!(created_at: 1.hour.ago)

      expect(panel.preview_panel_versions.reload.to_a).to eq([ second_version, first_version ])
    end
  end

  it "is destroyed with its preview panel" do
    version = panel.create_version!("index.html" => "<h1>hi</h1>")

    expect { panel.destroy }.to change { described_class.where(id: version.id).count }.by(-1)
  end
end
