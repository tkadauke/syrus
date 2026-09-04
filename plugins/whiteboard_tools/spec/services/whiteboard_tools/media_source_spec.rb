require "rails_helper"

RSpec.describe WhiteboardTools::MediaSource do
  let(:repo) { Factories.repository }
  let(:chat) { ChatSession.create!(repository: repo, user: repo.user) }
  let(:other_chat) { ChatSession.create!(repository: repo, user: repo.user) }

  def snapshot(session, name: "Board")
    WhiteboardSnapshot.create!(
      chat_session: session, name: name,
      scene_json: { "elements" => [ { "id" => "a" } ], "appState" => {}, "files" => {} },
      snapshot_kind: "manual", element_count: 1
    )
  end

  it "registers the snapshot kind" do
    expect(described_class.chat_media_kind).to eq("snapshot")
    expect(ChatMediaSources.for_kind("snapshot")).to eq(described_class)
  end

  it "scopes existence to the chat session" do
    mine = snapshot(chat)
    theirs = snapshot(other_chat)

    expect(described_class.chat_media_exists?(chat_session: chat, id: mine.id)).to be(true)
    expect(described_class.chat_media_exists?(chat_session: chat, id: theirs.id)).to be(false)
  end

  it "attaches a snapshot to a Job as a pending_snapshot document" do
    saved = snapshot(chat, name: "Architecture")
    job = Factories.job_record(user: repo.user, repository: repo)

    document = described_class.attach_chat_media(chat_session: chat, job: job, ref: "snapshot:#{saved.id}", id: saved.id)

    expect(document.kind).to eq("pending_snapshot")
    expect(document.title).to eq("Architecture")
    expect(document.source_url).to eq("snapshot:#{saved.id}")
  end

  it "returns nil for a snapshot from another chat" do
    theirs = snapshot(other_chat)
    job = Factories.job_record(user: repo.user, repository: repo)

    expect(described_class.attach_chat_media(chat_session: chat, job: job, ref: "snapshot:#{theirs.id}", id: theirs.id)).to be_nil
  end

  it "lists snapshots and reports the live element count as context" do
    snapshot(chat, name: "One")
    Whiteboard.create!(chat_session: chat, scene_json: { "elements" => [ { "id" => "x" }, { "id" => "y" } ], "appState" => {}, "files" => {} })

    entries = described_class.list_chat_media(chat_session: chat)

    expect(entries.map { |entry| entry[:kind] }).to eq([ "snapshot" ])
    expect(entries.first[:name]).to eq("One")
    expect(described_class.chat_media_context(chat_session: chat)).to eq(whiteboard_element_count: 2)
  end
end
