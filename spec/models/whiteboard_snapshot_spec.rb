require "rails_helper"

RSpec.describe WhiteboardSnapshot do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  it "validates required attributes" do
    snapshot = described_class.new(chat_session: chat_session)

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:scene_json]).to include("can't be blank")
    expect(snapshot.errors[:snapshot_kind]).to include("can't be blank")
    expect(snapshot.errors[:element_count]).to include("can't be blank")
  end

  it "validates snapshot kind" do
    snapshot = described_class.new(
      chat_session: chat_session,
      scene_json: { "elements" => [] },
      snapshot_kind: "bogus",
      element_count: 0
    )

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:snapshot_kind]).to include("is not included in the list")
  end

  it "orders newest snapshots first by default" do
    older = described_class.create!(
      chat_session: chat_session,
      scene_json: { "elements" => [] },
      snapshot_kind: "manual",
      element_count: 0,
      created_at: 2.hours.ago
    )
    newer = described_class.create!(
      chat_session: chat_session,
      scene_json: { "elements" => [] },
      snapshot_kind: "manual",
      element_count: 0,
      created_at: 1.hour.ago
    )

    expect(described_class.limit(2)).to eq([ newer, older ])
  end

  it "creates a snapshot from an Excalidraw scene" do
    scene = {
      "elements" => [ { "id" => "box-1" }, { "id" => "box-2" } ],
      "appState" => { "viewBackgroundColor" => "#ffffff" },
      "files" => { "file-1" => { "mimeType" => "image/png" } }
    }

    snapshot = described_class.create_from_scene!(
      chat_session: chat_session,
      scene: scene,
      kind: "manual",
      name: "Milestone"
    )

    expect(snapshot).to have_attributes(
      chat_session: chat_session,
      name: "Milestone",
      snapshot_kind: "manual",
      element_count: 2,
      scene_json: scene
    )
  end

  it "auto-generates a name when none is provided" do
    travel_to Time.zone.local(2026, 6, 25, 14, 30, 0) do
      snapshot = described_class.create_from_scene!(
        chat_session: chat_session,
        scene: { "elements" => [] },
        kind: "auto_clear"
      )

      expect(snapshot.name).to eq("Before clear - Jun 25 14:30")
    end
  end

  describe ".default_name_for" do
    it "prefixes auto_clear names with 'Before clear'" do
      travel_to Time.zone.local(2026, 6, 25, 10, 0, 0) do
        expect(described_class.default_name_for("auto_clear")).to eq("Before clear - Jun 25 10:00")
      end
    end

    it "prefixes auto_before_load names with 'Before load'" do
      travel_to Time.zone.local(2026, 6, 25, 10, 0, 0) do
        expect(described_class.default_name_for("auto_before_load")).to eq("Before load - Jun 25 10:00")
      end
    end

    it "uses 'Snapshot' as the default prefix for manual kind" do
      travel_to Time.zone.local(2026, 6, 25, 10, 0, 0) do
        expect(described_class.default_name_for("manual")).to eq("Snapshot - Jun 25 10:00")
      end
    end
  end

  it "is destroyed with its chat session" do
    snapshot = described_class.create!(
      chat_session: chat_session,
      scene_json: { "elements" => [] },
      snapshot_kind: "manual",
      element_count: 0
    )

    expect { chat_session.destroy }.to change { described_class.where(id: snapshot.id).count }.by(-1)
  end
end
