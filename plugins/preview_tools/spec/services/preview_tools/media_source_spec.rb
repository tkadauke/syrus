require "rails_helper"

RSpec.describe PreviewTools::MediaSource do
  let(:repo) { Factories.repository }
  let(:chat) { ChatSession.create!(repository: repo, user: repo.user) }
  let(:other_chat) { ChatSession.create!(repository: repo, user: repo.user) }

  def version_for(session, filenames: [ "index.html" ])
    panel = session.preview_panels.create!(title: "Mockup", state: "open")
    version = panel.preview_panel_versions.create!
    filenames.each do |name|
      version.files.attach(io: StringIO.new("<h1>hi</h1>"), filename: name, content_type: "text/html")
    end
    version
  end

  it "registers the preview_panel_version kind" do
    expect(described_class.chat_media_kind).to eq("preview_panel_version")
    expect(ChatMediaSources.for_kind("preview_panel_version")).to eq(described_class)
  end

  it "scopes existence to the chat session's own panels" do
    mine = version_for(chat)
    theirs = version_for(other_chat)

    expect(described_class.chat_media_exists?(chat_session: chat, id: mine.id)).to be(true)
    expect(described_class.chat_media_exists?(chat_session: chat, id: theirs.id)).to be(false)
  end

  it "attaches every file on the version" do
    version = version_for(chat, filenames: [ "index.html", "app.css" ])
    job = Factories.job_record(user: repo.user, repository: repo)

    documents = described_class.attach_chat_media(chat_session: chat, job: job, ref: "preview_panel_version:#{version.id}", id: version.id)

    expect(documents.map(&:title)).to match_array([ "index.html", "app.css" ])
    expect(documents.map(&:kind).uniq).to eq([ "file" ])
  end

  it "returns nil for a version belonging to another chat" do
    theirs = version_for(other_chat)
    job = Factories.job_record(user: repo.user, repository: repo)

    expect(described_class.attach_chat_media(chat_session: chat, job: job, ref: "preview_panel_version:#{theirs.id}", id: theirs.id)).to be_nil
  end
end
