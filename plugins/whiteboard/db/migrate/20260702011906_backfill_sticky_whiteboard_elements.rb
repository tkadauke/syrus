class BackfillStickyWhiteboardElements < ActiveRecord::Migration[8.1]
  class MigrationWhiteboard < ActiveRecord::Base
    self.table_name = "whiteboards"
  end

  def up
    return unless table_exists?(:whiteboards)

    MigrationWhiteboard.reset_column_information
    MigrationWhiteboard.find_each do |whiteboard|
      scene = whiteboard.scene_json || {}
      elements = Array(scene["elements"])
      next unless elements.any? { |el| el["type"] == "sticky" }

      remapped = elements.map do |el|
        next el unless el["type"] == "sticky"

        el.merge(
          "type" => "rectangle",
          "backgroundColor" => el["backgroundColor"].presence || "#fef08a",
          "strokeColor" => "#854d0e"
        )
      end

      whiteboard.update_columns(
        scene_json: scene.merge("elements" => remapped),
        version: whiteboard.version.to_i + 1,
        last_edited_at: Time.current,
        updated_at: Time.current
      )
    rescue => e
      Rails.logger.warn("BackfillStickyWhiteboardElements: skipped whiteboard #{whiteboard.id}: #{e.message}")
    end
  end

  def down
    # Irreversible — cannot distinguish backfilled rectangles from originals.
  end
end
