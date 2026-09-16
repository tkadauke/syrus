require "rails_helper"
require Rails.root.join("plugins/whiteboard/db/migrate/20260702011906_backfill_sticky_whiteboard_elements")

RSpec.describe BackfillStickyWhiteboardElements, :ci_only do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:whiteboard_records) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "whiteboards"
    end
  end

  before do
    connection.drop_table(:whiteboards, if_exists: true)
    connection.create_table(:whiteboards) do |t|
      t.bigint :chat_session_id
      t.json :scene_json, null: false
      t.integer :version, null: false, default: 0
      t.datetime :last_edited_at
      t.timestamps
    end

    whiteboard_records.reset_column_information
  end

  after do
    connection.drop_table(:whiteboards, if_exists: true)
  end

  it "remaps sticky elements to rectangles with yellow styling" do
    whiteboard = whiteboard_records.create!(
      scene_json: {
        "elements" => [
          { "id" => "s1", "type" => "sticky", "x" => 0, "y" => 0, "width" => 100, "height" => 80 },
          { "id" => "r1", "type" => "rectangle", "x" => 200, "y" => 0, "width" => 100, "height" => 80 }
        ],
        "appState" => {},
        "files" => {}
      }
    )

    migration.up

    elements = whiteboard.reload.scene_json["elements"]
    sticky = elements.find { |el| el["id"] == "s1" }
    rect = elements.find { |el| el["id"] == "r1" }

    expect(sticky).to include("type" => "rectangle", "backgroundColor" => "#fef08a", "strokeColor" => "#854d0e")
    expect(rect).to include("type" => "rectangle")
  end

  it "preserves an explicit backgroundColor set on a sticky element" do
    whiteboard = whiteboard_records.create!(
      scene_json: {
        "elements" => [
          { "id" => "s1", "type" => "sticky", "backgroundColor" => "#bbf7d0", "x" => 0, "y" => 0, "width" => 100, "height" => 80 }
        ],
        "appState" => {},
        "files" => {}
      }
    )

    migration.up

    element = whiteboard.reload.scene_json["elements"].first
    expect(element).to include("type" => "rectangle", "backgroundColor" => "#bbf7d0", "strokeColor" => "#854d0e")
  end

  it "is idempotent — re-running leaves no sticky elements" do
    whiteboard = whiteboard_records.create!(
      scene_json: {
        "elements" => [ { "id" => "s1", "type" => "sticky", "x" => 0, "y" => 0, "width" => 100, "height" => 80 } ],
        "appState" => {},
        "files" => {}
      }
    )

    migration.up
    migration.up

    elements = whiteboard.reload.scene_json["elements"]
    expect(elements.map { |el| el["type"] }).not_to include("sticky")
    expect(elements.first).to include("type" => "rectangle")
  end

  it "skips whiteboards with no sticky elements" do
    whiteboard = whiteboard_records.create!(
      scene_json: {
        "elements" => [ { "id" => "r1", "type" => "rectangle", "x" => 0, "y" => 0, "width" => 100, "height" => 80 } ],
        "appState" => {},
        "files" => {}
      }
    )
    version_before = whiteboard.reload.version

    migration.up

    expect(whiteboard.reload.version).to eq(version_before)
  end
end
