require "rails_helper"
require Rails.root.join("db/migrate/20260702011906_backfill_sticky_whiteboard_elements")

RSpec.describe BackfillStickyWhiteboardElements do
  let(:migration) { described_class.new }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  it "remaps sticky elements to rectangles with yellow styling" do
    whiteboard = chat_session.create_whiteboard!(
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

    elements = whiteboard.reload.elements
    sticky = elements.find { |el| el["id"] == "s1" }
    rect = elements.find { |el| el["id"] == "r1" }

    expect(sticky).to include("type" => "rectangle", "backgroundColor" => "#fef08a", "strokeColor" => "#854d0e")
    expect(rect).to include("type" => "rectangle")
  end

  it "preserves an explicit backgroundColor set on a sticky element" do
    whiteboard = chat_session.create_whiteboard!(
      scene_json: {
        "elements" => [
          { "id" => "s1", "type" => "sticky", "backgroundColor" => "#bbf7d0", "x" => 0, "y" => 0, "width" => 100, "height" => 80 }
        ],
        "appState" => {},
        "files" => {}
      }
    )

    migration.up

    element = whiteboard.reload.elements.first
    expect(element).to include("type" => "rectangle", "backgroundColor" => "#bbf7d0", "strokeColor" => "#854d0e")
  end

  it "is idempotent — re-running leaves no sticky elements" do
    whiteboard = chat_session.create_whiteboard!(
      scene_json: {
        "elements" => [ { "id" => "s1", "type" => "sticky", "x" => 0, "y" => 0, "width" => 100, "height" => 80 } ],
        "appState" => {},
        "files" => {}
      }
    )

    migration.up
    migration.up

    elements = whiteboard.reload.elements
    expect(elements.map { |el| el["type"] }).not_to include("sticky")
    expect(elements.first).to include("type" => "rectangle")
  end

  it "skips whiteboards with no sticky elements" do
    whiteboard = chat_session.create_whiteboard!(
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
