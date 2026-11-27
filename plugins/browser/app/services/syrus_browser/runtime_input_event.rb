module SyrusBrowser
  # Compatibility adapter for runtime_input. Browser input must use the same
  # Playwright-backed BrowserTool classes as the granular interaction tools;
  # synthetic DOM events are not native input and break controlled fields.
  class RuntimeInputEvent
    class << self
      def for(event)
        type = event["type"].to_s
        types.fetch(type, Unknown).new(event)
      end

      private

      def types
        { "click" => Click, "pointer" => Pointer, "touch" => Pointer,
          "fill" => Fill, "text" => Fill, "type" => Fill,
          "hover" => Hover, "keyboard" => Keyboard, "key" => Keyboard,
          "drag" => Drag, "drop" => Drop, "upload" => Upload }
      end
    end

    def initialize(event)
      @event = event.to_h.stringify_keys
    end

    def deliver(runtime_session, owner: "agent")
      tool.call(server_context: { runtime_session: runtime_session, runtime_control_owner: owner }, **arguments.symbolize_keys)
    end

    private

    attr_reader :event

    def tool = raise NotImplementedError
    def arguments = {}
    def target = event["target"].presence || event["ref"].presence

    class Click < RuntimeInputEvent
      def tool = ClickTool
      def arguments = { target: target, element: event["element"] }.compact
    end

    class Pointer < Click
      def arguments
        return super if (event["action"].presence || "click") == "click" && target.present?
        { target: nil, element: "pointer input requires action=click and a stable target/ref" }
      end
    end

    class Fill < RuntimeInputEvent
      def tool = FillTool
      def arguments = { target: target, element: event["element"], text: event["text"].presence || event["value"] }.compact
    end

    class Hover < RuntimeInputEvent
      def tool = HoverTool
      def arguments = { target: target, element: event["element"] }.compact
    end

    class Keyboard < RuntimeInputEvent
      def tool = PressKeyTool
      def arguments = { key: event["key"].presence || event["text"] }.compact
    end

    class Drag < RuntimeInputEvent
      def tool = DragTool
      def arguments = { start_target: event["start_target"].presence || event["start_ref"], end_target: event["end_target"].presence || event["end_ref"], start_element: event["start_element"], end_element: event["end_element"] }.compact
    end

    class Drop < RuntimeInputEvent
      def tool = DropTool
      def arguments = { target: target, element: event["element"], paths: event["paths"] }.compact
    end

    class Upload < RuntimeInputEvent
      def tool = FileUploadTool
      def arguments = { paths: event["paths"] }.compact
    end

    class Unknown < RuntimeInputEvent
      def deliver(_runtime_session, owner: "agent")
        BrowserTool.error("unsupported_input_event: #{event['type']}")
      end
    end
  end
end
