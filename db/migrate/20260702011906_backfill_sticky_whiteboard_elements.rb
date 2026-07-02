class BackfillStickyWhiteboardElements < ActiveRecord::Migration[8.1]
  def up
    Whiteboard.find_each do |whiteboard|
      elements = whiteboard.elements
      next unless elements.any? { |el| el["type"] == "sticky" }

      remapped = elements.map do |el|
        next el unless el["type"] == "sticky"

        el.merge(
          "type" => "rectangle",
          "backgroundColor" => el["backgroundColor"].presence || "#fef08a",
          "strokeColor" => "#854d0e"
        )
      end

      whiteboard.replace_elements!(remapped)
    rescue => e
      Rails.logger.warn("BackfillStickyWhiteboardElements: skipped whiteboard #{whiteboard.id}: #{e.message}")
    end
  end

  def down
    # Irreversible — cannot distinguish backfilled rectangles from originals.
  end
end
