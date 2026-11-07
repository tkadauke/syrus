require "rails_helper"

RSpec.describe PreviewPanel::ZipExporter do
  it "caches the immutable archive by version id" do
    user = Factories.user
    chat = ChatSession.create!(user: user)
    panel = PreviewPanel::Service.open!(chat_session: chat, title: "Cached", files: { "index.html" => "first" })
    exporter = described_class.new(panel.current_version)
    cache = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(cache)

    expect(exporter).to receive(:build_zip).once.and_call_original

    expect(exporter.call).to eq(exporter.call)
  end

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  it "zips every attached file under its relative path" do
    panel = PreviewPanel::Service.open!(
      chat_session: chat_session,
      title: "Widget preview",
      files: { "index.html" => "<h1>hi</h1>", "css/app.css" => "body { color: red; }" }
    )

    zip_bytes = described_class.new(panel.current_version).call

    Zip::File.open_buffer(zip_bytes) do |zip|
      expect(zip.map(&:name)).to contain_exactly("index.html", "css/app.css")
      expect(zip.read("index.html")).to eq("<h1>hi</h1>")
      expect(zip.read("css/app.css")).to eq("body { color: red; }")
    end
  end

  it "produces an empty archive for a version with no files" do
    panel = PreviewPanel::Service.open!(chat_session: chat_session, title: "Widget preview", files: {})

    zip_bytes = described_class.new(panel.current_version).call

    Zip::File.open_buffer(zip_bytes) do |zip|
      expect(zip.to_a).to be_empty
    end
  end
end
