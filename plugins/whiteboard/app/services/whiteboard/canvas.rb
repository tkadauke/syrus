module Whiteboard
  module Canvas
    class ElementLimitExceeded < StandardError; end

    SHAPE_TYPES = %w[rectangle ellipse diamond sticky].freeze
    ELEMENT_TYPES = %w[selection rectangle ellipse diamond text line arrow freedraw image frame magicframe iframe embeddable].freeze
    DEFAULT_COLOR = "#f8fafc"
    DEFAULT_STROKE = "#1f2937"
    ARROWHEAD_TYPES = %w[
      arrow
      bar
      dot
      circle
      circle_outline
      triangle
      triangle_outline
      diamond
      diamond_outline
      crowfoot_one
      crowfoot_many
      crowfoot_one_or_many
    ].freeze
    CONNECTOR_GEOMETRIES = {
      "rectangle" => :rectangle_connector_scale,
      "ellipse" => :ellipse_connector_scale,
      "diamond" => :diamond_connector_scale
    }.freeze

    module_function

    def read(chat_session)
      whiteboard = Whiteboard::Board.for(chat_session)
      return Whiteboard::Board.default_state unless whiteboard

      whiteboard.current_state
    end

    def mutate(chat_session, tool_name, args)
      whiteboard = nil
      result = nil

      Whiteboard::Board.transaction do
        whiteboard = find_or_create_whiteboard(chat_session).lock!
        scene = deep_dup_scene(whiteboard.current_state.except("version"))
        elements = scene.fetch("elements")
        result = yield(elements, scene)
        ensure_within_element_limit!(elements)

        whiteboard.scene_json = scene
        whiteboard.version += 1
        whiteboard.last_edited_at = Time.current
        whiteboard.save!
      end

      # We deliberately do NOT persist a parallel structured tool_use
      # row here. The agent's stream-json log_sink already creates an
      # abbreviated tool_use ("● draw_shape(rectangle)") for every MCP
      # invocation. Persisting a second row was duplicate bookkeeping
      # that produced two entries per draw_shape in the chat UI.

      whiteboard.broadcast_scene
      result.merge(version: whiteboard.version)
    end

    def find_or_create_whiteboard(chat_session)
      Whiteboard::Board.for!(chat_session)
    end

    def shape_element(type:, x:, y:, width:, height:, color: nil, **)
      if type.to_s == "sticky"
        effective_type = "rectangle"
        background = color.presence || "#fef08a"
        stroke = "#854d0e"
      else
        effective_type = type
        background = color.presence || DEFAULT_COLOR
        stroke = DEFAULT_STROKE
      end
      base_element(type: effective_type, x: x, y: y, width: width, height: height).merge(
        "backgroundColor" => background,
        "strokeColor" => stroke,
        "boundElements" => []
      )
    end

    def line_element(type:, x:, y:, points:, stroke_color: nil, stroke_width: nil, start_arrowhead: nil, end_arrowhead: nil)
      normalized_points = normalize_points(points)
      dimensions = dimensions_for_points(normalized_points)
      linear_type = type.to_s
      raise ArgumentError, "type must be line or arrow" unless %w[line arrow].include?(linear_type)

      element = base_element(
        type: linear_type,
        x: x,
        y: y,
        width: dimensions.fetch("width"),
        height: dimensions.fetch("height")
      ).merge(
        "strokeColor" => stroke_color.presence || DEFAULT_STROKE,
        "backgroundColor" => "transparent",
        "strokeWidth" => integer_or_default(stroke_width, 2),
        "fillStyle" => "hachure",
        "points" => normalized_points,
        "lastCommittedPoint" => nil,
        "startBinding" => nil,
        "endBinding" => nil,
        "startArrowhead" => normalize_arrowhead(start_arrowhead),
        "endArrowhead" => linear_type == "arrow" ? normalize_arrowhead(end_arrowhead, default: "arrow") : normalize_arrowhead(end_arrowhead)
      )
      element["elbowed"] = false if linear_type == "arrow"
      element
    end

    def freedraw_element(x:, y:, points:, pressures: nil, simulate_pressure: true, stroke_color: nil, stroke_width: nil)
      normalized_points = normalize_points(points)
      dimensions = dimensions_for_points(normalized_points)
      base_element(type: "freedraw", x: x, y: y, width: dimensions.fetch("width"), height: dimensions.fetch("height")).merge(
        "strokeColor" => stroke_color.presence || DEFAULT_STROKE,
        "backgroundColor" => "transparent",
        "strokeWidth" => integer_or_default(stroke_width, 2),
        "fillStyle" => "hachure",
        "points" => normalized_points,
        "pressures" => normalize_pressures(pressures, normalized_points.length),
        "simulatePressure" => ActiveModel::Type::Boolean.new.cast(simulate_pressure),
        "lastCommittedPoint" => nil
      )
    end

    def frame_element(type:, x:, y:, width:, height:, name: nil)
      frame_type = type.to_s.presence || "frame"
      raise ArgumentError, "type must be frame or magicframe" unless %w[frame magicframe].include?(frame_type)

      base_element(type: frame_type, x: x, y: y, width: width, height: height).merge(
        "backgroundColor" => "transparent",
        "strokeColor" => DEFAULT_STROKE,
        "name" => name.presence
      )
    end

    def embed_element(type:, x:, y:, width:, height:, link:)
      embed_type = type.to_s.presence || "embeddable"
      raise ArgumentError, "type must be embeddable or iframe" unless %w[embeddable iframe].include?(embed_type)

      base_element(type: embed_type, x: x, y: y, width: width, height: height).merge(
        "backgroundColor" => "transparent",
        "strokeColor" => DEFAULT_STROKE,
        "link" => link.to_s
      )
    end

    def image_element(x:, y:, width:, height:, file_id:)
      base_element(type: "image", x: x, y: y, width: width, height: height).merge(
        "backgroundColor" => "transparent",
        "strokeColor" => "transparent",
        "fileId" => file_id,
        "status" => "saved",
        "scale" => [ 1, 1 ],
        "crop" => nil
      )
    end

    def file_record(data_url:, mime_type: nil, file_id: nil)
      id = file_id.presence || ExcalidrawId.generate
      now = (Time.current.to_f * 1000).to_i
      {
        "id" => id,
        "dataURL" => data_url.to_s,
        "mimeType" => mime_type.presence || mime_type_from_data_url(data_url),
        "created" => now,
        "lastRetrieved" => now
      }
    end

    def text_element(content:, x:, y:, font_size: nil)
      font_size = integer_or_default(font_size, 20)
      text = content.to_s
      lines = text.split("\n", -1)
      line_count = [ lines.length, 1 ].max
      longest_line = lines.max_by(&:length) || ""

      base_element(type: "text", x: x, y: y, width: [ longest_line.length * font_size * 0.6, font_size ].max.round(2), height: (font_size * 1.25 * line_count).round(2)).merge(
        "text" => text,
        "originalText" => text,
        "fontSize" => font_size,
        "fontFamily" => 1,
        "textAlign" => "left",
        "verticalAlign" => "top",
        "baseline" => font_size,
        "lineHeight" => 1.25,
        "containerId" => nil,
        "autoResize" => true
      )
    end

    # Labels in Excalidraw are not a field on the container shape —
    # they're a separate `text` element bound via `containerId` (and a
    # matching entry in the container's `boundElements` array).
    # Caller pushes both elements onto the scene and sets the
    # container's `boundElements`.
    def bound_label_element(container:, text:, font_size: 20)
      label = text.to_s
      lines = label.split("\n", -1)
      line_count = [ lines.length, 1 ].max
      longest_line = lines.max_by(&:length) || ""
      width = [ longest_line.length * font_size * 0.6, font_size * 2 ].max.round(2)
      height = (font_size * 1.25 * line_count).round(2)
      x = container.fetch("x").to_f + (container.fetch("width").to_f - width) / 2.0
      y = container.fetch("y").to_f + (container.fetch("height").to_f - height) / 2.0

      base_element(type: "text", x: x, y: y, width: width, height: height).merge(
        "text" => label,
        "originalText" => label,
        "fontSize" => font_size,
        "fontFamily" => 1,
        "textAlign" => "center",
        "verticalAlign" => "middle",
        "baseline" => font_size,
        "lineHeight" => 1.25,
        "containerId" => container.fetch("id"),
        "autoResize" => true
      )
    end

    def arrow_element(from_element, to_element)
      arrow_id = ExcalidrawId.generate
      start_center = center_of(from_element)
      end_center = center_of(to_element)
      start = connector_point(from_element, toward: end_center)
      finish = connector_point(to_element, toward: start_center)

      base_element(id: arrow_id, type: "arrow", x: start.fetch("x"), y: start.fetch("y"), width: finish.fetch("x") - start.fetch("x"), height: finish.fetch("y") - start.fetch("y")).merge(
        "points" => [ [ 0, 0 ], [ finish.fetch("x") - start.fetch("x"), finish.fetch("y") - start.fetch("y") ] ],
        "startBinding" => { "elementId" => from_element.fetch("id"), "focus" => 0, "gap" => 1 },
        "endBinding" => { "elementId" => to_element.fetch("id"), "focus" => 0, "gap" => 1 },
        "lastCommittedPoint" => nil,
        "startArrowhead" => nil,
        "endArrowhead" => "arrow",
        "elbowed" => false
      )
    end

    def bind_arrow_to_shapes!(elements, arrow)
      %w[startBinding endBinding].each do |binding_key|
        shape = find_element(elements, arrow.fetch(binding_key).fetch("elementId"))
        shape["boundElements"] = Array(shape["boundElements"])
        next if shape["boundElements"].any? { |bound| bound["id"] == arrow.fetch("id") }

        shape["boundElements"] << { "id" => arrow.fetch("id"), "type" => "arrow" }
      end
    end

    def remove_element!(elements, id)
      removed = elements.find { |element| element["id"] == id }
      raise ArgumentError, "unknown element id: #{id}" unless removed

      associated_ids = Array(removed["boundElements"])
        .select { |bound| bound["type"] == "text" }
        .map { |bound| bound["id"] }
      elements.delete(removed)
      elements.delete_if { |element| associated_ids.include?(element["id"]) }
      elements.each do |element|
        element["boundElements"] = Array(element["boundElements"]).reject { |bound| bound["id"] == id } if element["boundElements"]
      end

      return unless removed["type"] != "arrow"

      arrows = elements.select do |element|
        element["type"] == "arrow" &&
          [ element.dig("startBinding", "elementId"), element.dig("endBinding", "elementId") ].include?(id)
      end
      arrow_ids = arrows.map { |arrow| arrow["id"] }
      arrow_label_ids = arrows.flat_map do |arrow|
        Array(arrow["boundElements"]).select { |bound| bound["type"] == "text" }.map { |bound| bound["id"] }
      end
      elements.delete_if { |element| arrow_ids.include?(element["id"]) || arrow_label_ids.include?(element["id"]) }
    end

    def recalibrate_bound_arrows!(elements)
      elements.select { |element| element["type"] == "arrow" }.each do |arrow|
        recalibrate_arrow!(arrow, elements)
      end
    end

    def validate_elements!(elements)
      raise ArgumentError, "elements must be an array" unless elements.is_a?(Array)
      ensure_within_element_limit!(elements)

      elements.each do |element|
        raise ArgumentError, "each element must be an object" unless element.is_a?(Hash)

        type = (element["type"] || element[:type]).to_s
        raise ArgumentError, "element type is required" if type.empty?
        raise ArgumentError, "unsupported element type: #{type}" unless ELEMENT_TYPES.include?(type)
      end
    end

    def validate_scene!(elements:, app_state: nil, files: nil)
      validate_elements!(elements)
      raise ArgumentError, "appState must be an object" unless app_state.nil? || app_state.is_a?(Hash)
      raise ArgumentError, "files must be an object" unless files.nil? || files.is_a?(Hash)
    end

    def ensure_can_append_element!(elements)
      raise ElementLimitExceeded, Whiteboard::Board.element_limit_message if elements.size >= Whiteboard::Board::MAX_ELEMENTS
    end

    def ensure_within_element_limit!(elements)
      raise ElementLimitExceeded, Whiteboard::Board.element_limit_message if elements.size > Whiteboard::Board::MAX_ELEMENTS
    end

    def find_element(elements, id)
      element = elements.find { |candidate| candidate["id"] == id }
      raise ArgumentError, "unknown element id: #{id}" unless element

      element
    end

    def number(value, name)
      Float(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a number"
    end

    def positive_number(value, name)
      numeric = number(value, name)
      raise ArgumentError, "#{name} must be greater than 0" unless numeric.positive?

      numeric
    end

    def deep_dup_elements(elements)
      JSON.parse(JSON.generate(elements))
    end

    def deep_dup_scene(scene)
      JSON.parse(JSON.generate(scene))
    end

    def base_element(type:, x:, y:, width:, height:, id: ExcalidrawId.generate)
      now = (Time.current.to_f * 1000).to_i

      # Visual-style defaults (opacity / strokeWidth / strokeStyle /
      # roughness / fillStyle) must be present on the wire — Excalidraw's
      # `updateScene` (the broadcast-apply path) takes elements as-is
      # without normalizing, and missing values render invisible.
      # `initialData` does normalize, which is why reloads worked but
      # live agent draws came in transparent.
      {
        "id" => id,
        "type" => type,
        "x" => x,
        "y" => y,
        "width" => width,
        "height" => height,
        "angle" => 0,
        "strokeWidth" => 2,
        "strokeStyle" => "solid",
        "fillStyle" => "solid",
        "roughness" => 1,
        "opacity" => 100,
        "seed" => SecureRandom.random_number(1 << 31),
        "version" => 1,
        "versionNonce" => SecureRandom.random_number(1 << 31),
        "index" => nil,
        "isDeleted" => false,
        "groupIds" => [],
        "frameId" => nil,
        "boundElements" => nil,
        "roundness" => nil,
        "updated" => now,
        "link" => nil,
        "locked" => false
      }
    end

    def center_of(element)
      {
        "x" => element.fetch("x").to_f + (element.fetch("width").to_f / 2),
        "y" => element.fetch("y").to_f + (element.fetch("height").to_f / 2)
      }
    end

    # Find the intersection between the ray from an element's center toward
    # the other endpoint and the element's visible outline. Excalidraw keeps
    # the binding metadata responsible for subsequent browser-side edits; this
    # geometry supplies a correct initial scene and server-side move result.
    # Rotated, malformed, and unsupported elements deliberately fall back to
    # their center, preserving the behavior of older scenes.
    def connector_point(element, toward:)
      center = center_of(element)
      return center unless element.fetch("angle", 0).to_f.zero?

      half_width = element.fetch("width", 0).to_f.abs / 2.0
      half_height = element.fetch("height", 0).to_f.abs / 2.0
      return center unless half_width.positive? && half_height.positive?

      dx = toward.fetch("x").to_f - center.fetch("x")
      dy = toward.fetch("y").to_f - center.fetch("y")
      return center if dx.zero? && dy.zero?

      geometry = CONNECTOR_GEOMETRIES[element["type"]]
      scale = public_send(geometry, dx, dy, half_width, half_height) if geometry
      return center unless scale&.finite?

      { "x" => center.fetch("x") + dx * scale, "y" => center.fetch("y") + dy * scale }
    rescue KeyError, TypeError, ArgumentError
      center
    end

    def rectangle_connector_scale(dx, dy, half_width, half_height)
      1.0 / [ dx.abs / half_width, dy.abs / half_height ].max
    end

    def ellipse_connector_scale(dx, dy, half_width, half_height)
      1.0 / Math.sqrt((dx / half_width)**2 + (dy / half_height)**2)
    end

    def diamond_connector_scale(dx, dy, half_width, half_height)
      1.0 / (dx.abs / half_width + dy.abs / half_height)
    end

    def recalibrate_arrow!(arrow, elements)
      start_id = arrow.dig("startBinding", "elementId")
      end_id = arrow.dig("endBinding", "elementId")
      return if start_id.blank? || end_id.blank?

      start_element = elements.find { |element| element["id"] == start_id }
      end_element = elements.find { |element| element["id"] == end_id }
      return unless start_element && end_element

      start_center = center_of(start_element)
      end_center = center_of(end_element)
      start = connector_point(start_element, toward: end_center)
      finish = connector_point(end_element, toward: start_center)
      arrow["x"] = start.fetch("x")
      arrow["y"] = start.fetch("y")
      arrow["width"] = finish.fetch("x") - start.fetch("x")
      arrow["height"] = finish.fetch("y") - start.fetch("y")
      arrow["points"] = [ [ 0, 0 ], [ arrow["width"], arrow["height"] ] ]
      arrow["version"] = arrow.fetch("version", 0).to_i + 1
      arrow["updated"] = (Time.current.to_f * 1000).to_i

      Array(arrow["boundElements"]).select { |bound| bound["type"] == "text" }.each do |bound|
        label = elements.find { |element| element["id"] == bound["id"] && element["type"] == "text" }
        next unless label

        label["x"] = arrow.fetch("x").to_f + (arrow.fetch("width").to_f - label.fetch("width", 0).to_f) / 2.0
        label["y"] = arrow.fetch("y").to_f + (arrow.fetch("height").to_f - label.fetch("height", 0).to_f) / 2.0
        label["version"] = label.fetch("version", 0).to_i + 1
        label["updated"] = arrow["updated"]
      end
    end

    def integer_or_default(value, default)
      return default if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "font_size must be an integer"
    end

    def normalize_points(points)
      raise ArgumentError, "points must be an array" unless points.is_a?(Array)
      raise ArgumentError, "points must include at least two points" if points.size < 2

      points.map do |point|
        if point.is_a?(Array) && point.size >= 2
          [ number(point[0], "point x"), number(point[1], "point y") ]
        elsif point.is_a?(Hash)
          [ number(point["x"] || point[:x], "point x"), number(point["y"] || point[:y], "point y") ]
        else
          raise ArgumentError, "each point must be [x, y] or {x, y}"
        end
      end
    end

    def dimensions_for_points(points)
      xs = points.map(&:first)
      ys = points.map(&:second)
      {
        "width" => xs.max.to_f - xs.min.to_f,
        "height" => ys.max.to_f - ys.min.to_f
      }
    end

    def normalize_pressures(pressures, count)
      return [] if pressures.blank?
      raise ArgumentError, "pressures must be an array" unless pressures.is_a?(Array)
      raise ArgumentError, "pressures must match points length" unless pressures.length == count

      pressures.map { |pressure| number(pressure, "pressure") }
    end

    def normalize_arrowhead(value, default: nil)
      arrowhead = value.presence || default
      return nil unless arrowhead

      arrowhead = arrowhead.to_s
      raise ArgumentError, "unsupported arrowhead: #{arrowhead}" unless ARROWHEAD_TYPES.include?(arrowhead)

      arrowhead
    end

    def mime_type_from_data_url(data_url)
      match = data_url.to_s.match(/\Adata:([^;,]+)[;,]/)
      match ? match[1] : "application/octet-stream"
    end
  end
end
