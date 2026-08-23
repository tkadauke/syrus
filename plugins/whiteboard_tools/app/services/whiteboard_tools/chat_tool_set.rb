require "mcp"

module WhiteboardTools
  # Chat MCP tool set for the whiteboard: draw/move/delete/read/update the
  # live Excalidraw scene, plus save/clear/load named snapshots. Consolidates
  # what used to be 14 individual Mcp::Tools::* < MCP::Tool subclasses
  # (registered at tier: :deferred in app/services/mcp_tool_registry.rb) into
  # a single :chat_mcp_tool_set provider, mirroring PreviewTools::ChatToolSet.
  # All drawing logic lives in WhiteboardTools::Canvas; this class only owns
  # tool schema + param plumbing + response shaping.
  class ChatToolSet
    READ_SCENE     = "read_scene"
    DRAW_SHAPE     = "draw_shape"
    DRAW_TEXT      = "draw_text"
    DRAW_LINE      = "draw_line"
    DRAW_ARROW     = "draw_arrow"
    DRAW_FREEDRAW  = "draw_freedraw"
    DRAW_FRAME     = "draw_frame"
    DRAW_EMBED     = "draw_embed"
    DRAW_IMAGE     = "draw_image"
    MOVE_ELEMENT   = "move_element"
    DELETE_ELEMENT = "delete_element"
    UPDATE_SCENE   = "update_scene"
    SAVE_CANVAS    = "save_canvas"
    CLEAR_CANVAS   = "clear_canvas"
    LOAD_CANVAS    = "load_canvas"

    # Same tier the individual tools used to declare (tier: :deferred, no
    # feature_flag / required_roles) -- available in every chat once the
    # deferred tool tier is loaded.
    def self.available_for?(_chat_session, tier:)
      tier.to_sym == :deferred
    end

    # available_for? is the tier gate (deferred only, matching the tools'
    # former tier: :deferred registration); tier isn't otherwise consulted
    # here so a nil tier (used by Syrus::PluginRegistry's cross-plugin tool
    # name uniqueness check) still returns the full definition list.
    def self.tool_definitions(tier:)
      [
        {
          name: READ_SCENE,
          description: "Return the current whiteboard scene elements and version without rasterizing the canvas.",
          input_schema: { type: "object", properties: {} }
        },
        {
          name: DRAW_SHAPE,
          description: "Append a rectangle, ellipse, diamond, or sticky shape to the whiteboard scene. The sticky type renders as a yellow rectangle.",
          input_schema: {
            type: "object",
            required: %w[type x y width height],
            properties: {
              type: { type: "string", description: "One of rectangle, ellipse, diamond, or sticky. sticky renders as a yellow rectangle with amber border." },
              x: { type: "number" },
              y: { type: "number" },
              width: { type: "number" },
              height: { type: "number" },
              label: { type: "string" },
              color: { type: "string" }
            }
          }
        },
        {
          name: DRAW_TEXT,
          description: "Append a text element to the whiteboard scene.",
          input_schema: {
            type: "object",
            required: %w[content x y],
            properties: {
              content: { type: "string" },
              x: { type: "number" },
              y: { type: "number" },
              font_size: { type: "integer" }
            }
          }
        },
        {
          name: DRAW_LINE,
          description: "Append a line or unbound arrow to the whiteboard scene. Supports polyline points and Excalidraw arrowhead styles.",
          input_schema: {
            type: "object",
            required: %w[x y],
            properties: {
              type: { type: "string", enum: %w[line arrow], description: "Defaults to line. Use arrow for an unbound arrow." },
              x: { type: "number" },
              y: { type: "number" },
              width: { type: "number", description: "Used with height when points are omitted." },
              height: { type: "number", description: "Used with width when points are omitted." },
              points: { type: "array", description: "Optional local points as [x,y] arrays or {x,y} objects." },
              color: { type: "string" },
              stroke_width: { type: "integer" },
              start_arrowhead: { type: "string" },
              end_arrowhead: { type: "string" }
            }
          }
        },
        {
          name: DRAW_ARROW,
          description: "Append an arrow bound to two existing elements so it follows them when they move.",
          input_schema: {
            type: "object",
            required: %w[from_id to_id],
            properties: {
              from_id: { type: "string" },
              to_id: { type: "string" },
              label: { type: "string" }
            }
          }
        },
        {
          name: DRAW_FREEDRAW,
          description: "Append a freehand Excalidraw path to the whiteboard scene.",
          input_schema: {
            type: "object",
            required: %w[x y points],
            properties: {
              x: { type: "number" },
              y: { type: "number" },
              points: { type: "array", description: "Local points as [x,y] arrays or {x,y} objects." },
              pressures: { type: "array", description: "Optional pressure values, one per point." },
              simulate_pressure: { type: "boolean" },
              color: { type: "string" },
              stroke_width: { type: "integer" }
            }
          }
        },
        {
          name: DRAW_FRAME,
          description: "Append an Excalidraw frame or magicframe to the whiteboard scene.",
          input_schema: {
            type: "object",
            required: %w[x y width height],
            properties: {
              type: { type: "string", enum: %w[frame magicframe], description: "Defaults to frame." },
              x: { type: "number" },
              y: { type: "number" },
              width: { type: "number" },
              height: { type: "number" },
              name: { type: "string" }
            }
          }
        },
        {
          name: DRAW_EMBED,
          description: "Append an Excalidraw embeddable or iframe element with a link.",
          input_schema: {
            type: "object",
            required: %w[link x y width height],
            properties: {
              type: { type: "string", enum: %w[embeddable iframe], description: "Defaults to embeddable." },
              link: { type: "string" },
              x: { type: "number" },
              y: { type: "number" },
              width: { type: "number" },
              height: { type: "number" }
            }
          }
        },
        {
          name: DRAW_IMAGE,
          description: "Append an Excalidraw image element from a data URL and persist its BinaryFiles entry.",
          input_schema: {
            type: "object",
            required: %w[data_url x y width height],
            properties: {
              data_url: { type: "string", description: "Image data URL, for example data:image/png;base64,..." },
              mime_type: { type: "string" },
              file_id: { type: "string", description: "Optional stable Excalidraw file id." },
              x: { type: "number" },
              y: { type: "number" },
              width: { type: "number" },
              height: { type: "number" }
            }
          }
        },
        {
          name: MOVE_ELEMENT,
          description: "Move one whiteboard element to an absolute x/y position.",
          input_schema: {
            type: "object",
            required: %w[id x y],
            properties: {
              id: { type: "string" },
              x: { type: "number" },
              y: { type: "number" }
            }
          }
        },
        {
          name: DELETE_ELEMENT,
          description: "Remove one element from the whiteboard scene.",
          input_schema: {
            type: "object",
            required: %w[id],
            properties: {
              id: { type: "string" }
            }
          }
        },
        {
          name: UPDATE_SCENE,
          description: "Replace the whiteboard scene. Use only when high-level tools cannot express the change.",
          input_schema: {
            type: "object",
            required: %w[elements],
            properties: {
              elements: { type: "array", items: { type: "object" } },
              appState: { type: "object", description: "Optional Excalidraw appState to persist with the scene." },
              files: { type: "object", description: "Optional Excalidraw BinaryFiles map for image elements." }
            }
          }
        },
        {
          name: SAVE_CANVAS,
          description: "Save the current whiteboard scene as a named snapshot. Snapshots appear in the media tab and can be restored later with load_canvas.",
          input_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Optional operator-provided label for the snapshot." }
            }
          }
        },
        {
          name: CLEAR_CANVAS,
          description: "Remove all elements from the whiteboard scene. The current scene is automatically saved as a snapshot before clearing and can be restored from the media tab or via load_canvas.",
          input_schema: { type: "object", properties: {} }
        },
        {
          name: LOAD_CANVAS,
          description: "Load a previously saved canvas snapshot back onto the whiteboard. In merge mode (default), the snapshot's elements are appended to the current canvas with fresh IDs. In replace mode, the current canvas is auto-saved first, then replaced with the snapshot.",
          input_schema: {
            type: "object",
            required: %w[snapshot_id],
            properties: {
              snapshot_id: { type: "integer", description: "ID of the WhiteboardSnapshot to load." },
              mode: { type: "string", enum: %w[merge replace], description: "merge appends snapshot elements with fresh IDs; replace swaps the whole canvas after auto-saving the current scene." }
            }
          }
        }
      ]
    end

    def handle(tool_name, params, server_context)
      chat_session = server_context && server_context[:chat_session]
      return Mcp::Tools.invalid("No chat session available in this context.") unless chat_session

      params = normalize_params(params)

      case tool_name.to_s
      when READ_SCENE     then handle_read_scene(chat_session)
      when DRAW_SHAPE     then handle_draw_shape(chat_session, params)
      when DRAW_TEXT      then handle_draw_text(chat_session, params)
      when DRAW_LINE      then handle_draw_line(chat_session, params)
      when DRAW_ARROW     then handle_draw_arrow(chat_session, params)
      when DRAW_FREEDRAW  then handle_draw_freedraw(chat_session, params)
      when DRAW_FRAME     then handle_draw_frame(chat_session, params)
      when DRAW_EMBED     then handle_draw_embed(chat_session, params)
      when DRAW_IMAGE     then handle_draw_image(chat_session, params)
      when MOVE_ELEMENT   then handle_move_element(chat_session, params)
      when DELETE_ELEMENT then handle_delete_element(chat_session, params)
      when UPDATE_SCENE   then handle_update_scene(chat_session, params)
      when SAVE_CANVAS    then handle_save_canvas(chat_session, params)
      when CLEAR_CANVAS   then handle_clear_canvas(chat_session)
      when LOAD_CANVAS    then handle_load_canvas(chat_session, params)
      else
        Mcp::Tools.invalid("Unknown whiteboard tool: #{tool_name.inspect}")
      end
    rescue Canvas::ElementLimitExceeded => e
      Mcp::Tools.tool_error(e.message)
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      Mcp::Tools.invalid(e.message)
    end

    private

    def handle_read_scene(chat_session)
      Mcp::Tools.success(Canvas.read(chat_session))
    end

    def handle_draw_shape(chat_session, params)
      type = params[:type].to_s
      return Mcp::Tools.invalid("type must be rectangle, ellipse, diamond, or sticky") unless Canvas::SHAPE_TYPES.include?(type)

      args = {
        "type" => type,
        "x" => Canvas.number(params[:x], "x"),
        "y" => Canvas.number(params[:y], "y"),
        "width" => Canvas.positive_number(params[:width], "width"),
        "height" => Canvas.positive_number(params[:height], "height"),
        "label" => params[:label],
        "color" => params[:color]
      }.compact

      result = Canvas.mutate(chat_session, DRAW_SHAPE, args) do |elements|
        Canvas.ensure_can_append_element!(elements)
        element = Canvas.shape_element(**args.symbolize_keys.except(:label))
        elements << element

        label_text = args["label"].to_s.strip
        if label_text.present?
          Canvas.ensure_can_append_element!(elements)
          label = Canvas.bound_label_element(container: element, text: label_text)
          element["boundElements"] = (element["boundElements"] || []) + [ { "id" => label.fetch("id"), "type" => "text" } ]
          elements << label
        end

        { id: element.fetch("id") }
      end

      Mcp::Tools.success(result)
    end

    def handle_draw_text(chat_session, params)
      content = params[:content].to_s
      return Mcp::Tools.invalid("content is required") if content.empty?

      args = {
        "content" => content,
        "x" => Canvas.number(params[:x], "x"),
        "y" => Canvas.number(params[:y], "y"),
        "font_size" => params[:font_size]
      }.compact

      result = Canvas.mutate(chat_session, DRAW_TEXT, args) do |elements|
        Canvas.ensure_can_append_element!(elements)
        element = Canvas.text_element(**args.symbolize_keys)
        elements << element
        { id: element.fetch("id") }
      end

      Mcp::Tools.success(result)
    end

    def handle_draw_line(chat_session, params)
      type = params[:type].presence || "line"
      x = Canvas.number(params[:x], "x")
      y = Canvas.number(params[:y], "y")
      points = params[:points] || default_line_points(params[:width], params[:height])

      args = {
        "type" => type,
        "x" => x,
        "y" => y,
        "points" => points,
        "color" => params[:color],
        "stroke_width" => params[:stroke_width],
        "start_arrowhead" => params[:start_arrowhead],
        "end_arrowhead" => params[:end_arrowhead]
      }.compact

      result = Canvas.mutate(chat_session, DRAW_LINE, args) do |elements|
        Canvas.ensure_can_append_element!(elements)
        element = Canvas.line_element(
          type: type,
          x: x,
          y: y,
          points: points,
          stroke_color: params[:color],
          stroke_width: params[:stroke_width],
          start_arrowhead: params[:start_arrowhead],
          end_arrowhead: params[:end_arrowhead]
        )
        elements << element
        { id: element.fetch("id") }
      end

      Mcp::Tools.success(result)
    end

    def default_line_points(width, height)
      [
        [ 0, 0 ],
        [ Canvas.number(width || 100, "width"), Canvas.number(height || 0, "height") ]
      ]
    end

    def handle_draw_arrow(chat_session, params)
      from_id = params[:from_id].to_s
      to_id = params[:to_id].to_s
      return Mcp::Tools.invalid("from_id is required") if from_id.empty?
      return Mcp::Tools.invalid("to_id is required") if to_id.empty?

      label = params[:label]
      args = { "from_id" => from_id, "to_id" => to_id, "label" => label }.compact

      result = Canvas.mutate(chat_session, DRAW_ARROW, args) do |elements|
        Canvas.ensure_can_append_element!(elements)
        from_element = Canvas.find_element(elements, from_id)
        to_element = Canvas.find_element(elements, to_id)
        arrow = Canvas.arrow_element(from_element, to_element)
        arrow["label"] = label.to_s if label.present?
        elements << arrow
        Canvas.bind_arrow_to_shapes!(elements, arrow)
        { id: arrow.fetch("id") }
      end

      Mcp::Tools.success(result)
    end

    def handle_draw_freedraw(chat_session, params)
      x = Canvas.number(params[:x], "x")
      y = Canvas.number(params[:y], "y")
      points = params[:points]
      pressures = params[:pressures]
      simulate_pressure = params.key?(:simulate_pressure) ? params[:simulate_pressure] : true
      color = params[:color]
      stroke_width = params[:stroke_width]

      args = {
        "x" => x,
        "y" => y,
        "points" => points,
        "pressures" => pressures,
        "simulate_pressure" => simulate_pressure,
        "color" => color,
        "stroke_width" => stroke_width
      }.compact

      result = Canvas.mutate(chat_session, DRAW_FREEDRAW, args) do |elements|
        Canvas.ensure_can_append_element!(elements)
        element = Canvas.freedraw_element(
          x: x,
          y: y,
          points: points,
          pressures: pressures,
          simulate_pressure: simulate_pressure,
          stroke_color: color,
          stroke_width: stroke_width
        )
        elements << element
        { id: element.fetch("id") }
      end

      Mcp::Tools.success(result)
    end

    def handle_draw_frame(chat_session, params)
      type = params[:type].presence || "frame"
      name = params[:name]
      x = params[:x]
      y = params[:y]
      width = params[:width]
      height = params[:height]

      args = { "type" => type, "x" => x, "y" => y, "width" => width, "height" => height, "name" => name }.compact

      result = Canvas.mutate(chat_session, DRAW_FRAME, args) do |elements|
        Canvas.ensure_can_append_element!(elements)
        element = Canvas.frame_element(
          type: type,
          x: Canvas.number(x, "x"),
          y: Canvas.number(y, "y"),
          width: Canvas.positive_number(width, "width"),
          height: Canvas.positive_number(height, "height"),
          name: name
        )
        elements << element
        { id: element.fetch("id") }
      end

      Mcp::Tools.success(result)
    end

    def handle_draw_embed(chat_session, params)
      link = params[:link].to_s
      return Mcp::Tools.invalid("link is required") if link.blank?

      type = params[:type].presence || "embeddable"
      x = params[:x]
      y = params[:y]
      width = params[:width]
      height = params[:height]

      args = { "type" => type, "link" => link, "x" => x, "y" => y, "width" => width, "height" => height }

      result = Canvas.mutate(chat_session, DRAW_EMBED, args) do |elements|
        Canvas.ensure_can_append_element!(elements)
        element = Canvas.embed_element(
          type: type,
          link: link,
          x: Canvas.number(x, "x"),
          y: Canvas.number(y, "y"),
          width: Canvas.positive_number(width, "width"),
          height: Canvas.positive_number(height, "height")
        )
        elements << element
        { id: element.fetch("id") }
      end

      Mcp::Tools.success(result)
    end

    def handle_draw_image(chat_session, params)
      data_url = params[:data_url].to_s
      return Mcp::Tools.invalid("data_url must be a data URL") unless data_url.start_with?("data:")

      mime_type = params[:mime_type]
      file_id = params[:file_id]
      x = params[:x]
      y = params[:y]
      width = params[:width]
      height = params[:height]

      args = {
        "data_url" => data_url,
        "mime_type" => mime_type,
        "file_id" => file_id,
        "x" => x,
        "y" => y,
        "width" => width,
        "height" => height
      }.compact

      result = Canvas.mutate(chat_session, DRAW_IMAGE, args) do |elements, scene|
        Canvas.ensure_can_append_element!(elements)
        file = Canvas.file_record(data_url: data_url, mime_type: mime_type, file_id: file_id)
        element = Canvas.image_element(
          x: Canvas.number(x, "x"),
          y: Canvas.number(y, "y"),
          width: Canvas.positive_number(width, "width"),
          height: Canvas.positive_number(height, "height"),
          file_id: file.fetch("id")
        )
        scene["files"][file.fetch("id")] = file
        elements << element
        { id: element.fetch("id"), file_id: file.fetch("id") }
      end

      Mcp::Tools.success(result)
    end

    def handle_move_element(chat_session, params)
      id = params[:id].to_s
      return Mcp::Tools.invalid("id is required") if id.empty?

      args = {
        "id" => id,
        "x" => Canvas.number(params[:x], "x"),
        "y" => Canvas.number(params[:y], "y")
      }

      result = Canvas.mutate(chat_session, MOVE_ELEMENT, args) do |elements|
        element = Canvas.find_element(elements, id)
        element["x"] = args.fetch("x")
        element["y"] = args.fetch("y")
        element["version"] = element.fetch("version", 0).to_i + 1
        element["updated"] = (Time.current.to_f * 1000).to_i
        Canvas.recalibrate_bound_arrows!(elements)
        { id: id }
      end

      Mcp::Tools.success(result)
    end

    def handle_delete_element(chat_session, params)
      id = params[:id].to_s
      return Mcp::Tools.invalid("id is required") if id.empty?

      result = Canvas.mutate(chat_session, DELETE_ELEMENT, { "id" => id }) do |elements|
        Canvas.remove_element!(elements, id)
        { id: id }
      end

      Mcp::Tools.success(result)
    end

    def handle_update_scene(chat_session, params)
      elements = params[:elements]
      app_state = params[:appState]
      files = params[:files]
      Canvas.validate_scene!(elements: elements, app_state: app_state, files: files)

      args = { "elements" => elements, "appState" => app_state, "files" => files }.compact
      result = Canvas.mutate(chat_session, UPDATE_SCENE, args) do |current_elements, scene|
        current_elements.replace(Canvas.deep_dup_elements(elements))
        scene["appState"] = Canvas.deep_dup_scene(app_state) if app_state
        scene["files"] = Canvas.deep_dup_scene(files) if files
        { replaced: true }
      end

      Mcp::Tools.success(result)
    end

    def handle_save_canvas(chat_session, params)
      scene = Canvas.read(chat_session)
      return Mcp::Tools.success(saved: false, reason: "canvas is empty") if scene.fetch("elements").empty?

      snapshot = WhiteboardSnapshot.create_from_scene!(
        chat_session: chat_session,
        scene: scene,
        kind: "manual",
        name: params[:name]
      )

      Mcp::Tools.success(
        saved: true,
        snapshot_id: snapshot.id,
        name: snapshot.name,
        element_count: snapshot.element_count
      )
    end

    def handle_clear_canvas(chat_session)
      scene = Canvas.read(chat_session)
      snapshot = if scene.fetch("elements").any?
        WhiteboardSnapshot.create_from_scene!(
          chat_session: chat_session,
          scene: scene,
          kind: "auto_clear"
        )
      end

      result = Canvas.mutate(chat_session, CLEAR_CANVAS, {}) do |elements|
        elements.clear
        { cleared: true, snapshot_id: snapshot&.id }
      end

      Mcp::Tools.success(result)
    end

    def handle_load_canvas(chat_session, params)
      snapshot = chat_session.whiteboard_snapshots.find(params[:snapshot_id])
      snapshot_scene = Whiteboard.normalize_scene!(snapshot.scene_json)
      mode = params[:mode].presence || "merge"

      return Mcp::Tools.invalid("mode must be merge or replace") unless %w[merge replace].include?(mode)

      result = if mode == "replace"
        replace_canvas(chat_session, snapshot_scene)
      else
        merge_canvas(chat_session, snapshot_scene)
      end

      Mcp::Tools.success(result.merge(snapshot_id: snapshot.id, mode: mode))
    end

    def replace_canvas(chat_session, snapshot_scene)
      current_scene = Canvas.read(chat_session)
      auto_saved_snapshot = if current_scene.fetch("elements").any?
        WhiteboardSnapshot.create_from_scene!(
          chat_session: chat_session,
          scene: current_scene,
          kind: "auto_before_load"
        )
      end

      Canvas.mutate(chat_session, LOAD_CANVAS, { "mode" => "replace" }) do |elements, scene|
        snapshot_elements = Canvas.deep_dup_elements(snapshot_scene.fetch("elements"))
        Canvas.ensure_within_element_limit!(snapshot_elements)

        elements.replace(snapshot_elements)
        scene["appState"] = Canvas.deep_dup_scene(snapshot_scene.fetch("appState"))
        scene["files"] = Canvas.deep_dup_scene(snapshot_scene.fetch("files"))

        {
          loaded: true,
          elements_added: snapshot_elements.size,
          auto_saved_snapshot_id: auto_saved_snapshot&.id
        }
      end
    end

    def merge_canvas(chat_session, snapshot_scene)
      Canvas.mutate(chat_session, LOAD_CANVAS, { "mode" => "merge" }) do |elements, scene|
        snapshot_elements = remap_snapshot_elements(snapshot_scene.fetch("elements"))
        if elements.size + snapshot_elements.size > Whiteboard::MAX_ELEMENTS
          raise Canvas::ElementLimitExceeded, Whiteboard.element_limit_message
        end

        elements.concat(snapshot_elements)
        scene["files"].merge!(Canvas.deep_dup_scene(snapshot_scene.fetch("files")))

        {
          loaded: true,
          elements_added: snapshot_elements.size,
          auto_saved_snapshot_id: nil
        }
      end
    end

    def remap_snapshot_elements(elements)
      copied_elements = Canvas.deep_dup_elements(elements)
      id_map = copied_elements.each_with_object({}) do |element, memo|
        old_id = element["id"]
        next if old_id.blank?

        memo[old_id] = ExcalidrawId.generate
        element["id"] = memo.fetch(old_id)
      end

      copied_elements.each do |element|
        remap_element_references!(element, id_map)
      end

      copied_elements
    end

    def remap_element_references!(element, id_map)
      element["containerId"] = id_map.fetch(element["containerId"], element["containerId"]) if element["containerId"]
      element["frameId"] = id_map.fetch(element["frameId"], element["frameId"]) if element["frameId"]
      element["groupIds"] = Array(element["groupIds"]).map { |id| id_map.fetch(id, id) } if element.key?("groupIds")

      Array(element["boundElements"]).each do |bound_element|
        next unless bound_element.is_a?(Hash) && bound_element["id"]

        bound_element["id"] = id_map.fetch(bound_element["id"], bound_element["id"])
      end

      %w[startBinding endBinding].each do |binding_key|
        binding = element[binding_key]
        next unless binding.is_a?(Hash) && binding["elementId"]

        binding["elementId"] = id_map.fetch(binding["elementId"], binding["elementId"])
      end
    end

    def normalize_params(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
