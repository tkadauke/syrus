module SyrusBrowser
  # Compatibility adapter for runtime_input. Browser input must use the same
  # Playwright-backed BrowserTool classes as the granular interaction tools;
  # synthetic DOM events are not native input and break controlled fields.
  #
  # Both input models are supported: element-targeted input (a snapshot
  # target/ref) goes to the granular tools, and the Runtime panel's
  # coordinate clicks and target-less paste go to Playwright's own mouse and
  # keyboard (PointerAtTool, InsertTextTool). Every path passes through the
  # BrowserTool input-lease check, which records the event on the lease.
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

    def deliver(runtime_session, owner: "agent", lease: nil)
      tool.call(server_context: { runtime_session: runtime_session, runtime_control_owner: owner }, **arguments.symbolize_keys)
    end

    private

    attr_reader :event

    def tool = raise NotImplementedError
    def arguments = {}
    def target = event["target"].presence || event["ref"].presence

    MODIFIER_FLAGS = { "ctrl_key" => "Control", "alt_key" => "Alt", "shift_key" => "Shift", "meta_key" => "Meta" }.freeze

    def modifiers
      MODIFIER_FLAGS.filter_map { |flag, key| key if ActiveModel::Type::Boolean.new.cast(event[flag]) }
    end

    class Click < RuntimeInputEvent
      def tool = ClickTool
      def arguments = { target: target, element: event["element"] }.compact
    end

    class Pointer < Click
      def deliver(runtime_session, owner: "agent", lease: nil)
        unless (event["action"].presence || "click") == "click" && (target.present? || coordinates?)
          lease&.record_input!(event)
          return BrowserTool.error("pointer input requires action=click and either a stable target/ref or viewport coordinates")
        end

        super
      end

      def tool = target.present? ? ClickTool : PointerAtTool

      def arguments
        return super if target.present?

        { x: event["x"], y: event["y"], normalized_x: event["normalized_x"], normalized_y: event["normalized_y"],
          button: event["button"], pointer_type: event["pointer_type"].presence || (event["type"] == "touch" ? "touch" : "mouse"),
          modifiers: modifiers }.compact
      end

      private

      def coordinates?
        [ %w[normalized_x normalized_y], %w[x y] ].any? do |keys|
          keys.all? { |key| Float(event[key], exception: false)&.finite? }
        end
      end
    end

    class Fill < RuntimeInputEvent
      def tool = target.present? ? FillTool : InsertTextTool

      def arguments
        text = event["text"].presence || event["value"]
        return { text: text }.compact unless target.present?

        { target: target, element: event["element"], text: text }.compact
      end
    end

    class Hover < RuntimeInputEvent
      def tool = HoverTool
      def arguments = { target: target, element: event["element"] }.compact
    end

    class Keyboard < RuntimeInputEvent
      def tool = PressKeyTool

      # Carries held modifiers as a Playwright chord ("Control+Shift+S");
      # a modifier key pressed on its own is sent as itself.
      def arguments
        key = event["key"].presence || event["text"]
        return {} if key.blank?

        held = modifiers - [ key ]
        { key: (held + [ key ]).join("+") }
      end
    end

    class Drag < RuntimeInputEvent
      def tool = DragTool
      def arguments = { start_target: event["start_target"].presence || event["start_ref"], end_target: event["end_target"].presence || event["end_ref"], start_element: event["start_element"], end_element: event["end_element"] }.compact
    end

    class Drop < RuntimeInputEvent
      def tool = DropTool
      def arguments = { target: target, element: event["element"], paths: event["paths"], data: event["data"] }.compact
    end

    class Upload < RuntimeInputEvent
      def tool = FileUploadTool
      def arguments = { paths: event["paths"] }.compact
    end

    class Unknown < RuntimeInputEvent
      def deliver(_runtime_session, owner: "agent", lease: nil)
        lease&.record_input!(event)
        BrowserTool.error("unsupported_input_event: #{event['type']}")
      end
    end
  end
end
