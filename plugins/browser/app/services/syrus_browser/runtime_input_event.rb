module SyrusBrowser
  class RuntimeInputEvent
    class << self
      def for(event)
        type = event["type"].to_s
        types.fetch(type, Unknown).new(event)
      end

      private

      def types
        {
          "pointer" => Pointer,
          "touch" => Pointer,
          "keyboard" => Keyboard,
          "text" => Text
        }
      end
    end

    def initialize(event)
      @event = event.to_h.stringify_keys
    end

    def deliver(session)
      session.call_tool(name: "browser_evaluate", arguments: { "function" => function })
    end

    private

    attr_reader :event

    def function
      raise NotImplementedError
    end

    def payload_json
      event.to_json
    end

    class Pointer < RuntimeInputEvent
      private

      def function
        <<~JS.squish
          async () => {
            const event = #{payload_json};
            const viewportWidth = Number(event.viewport_width || event.page_width || window.innerWidth || document.documentElement.clientWidth || 0);
            const viewportHeight = Number(event.viewport_height || event.page_height || window.innerHeight || document.documentElement.clientHeight || 0);
            const normalizedX = Number(event.normalized_x ?? event.normalizedX);
            const normalizedY = Number(event.normalized_y ?? event.normalizedY);
            const rawX = Number(event.x);
            const rawY = Number(event.y);
            const x = Number.isFinite(normalizedX) && viewportWidth > 0 ? normalizedX * viewportWidth : rawX;
            const y = Number.isFinite(normalizedY) && viewportHeight > 0 ? normalizedY * viewportHeight : rawY;
            if (!Number.isFinite(x) || !Number.isFinite(y)) return { delivered: false, error: "invalid_coordinates" };
            const action = event.action || "click";
            const pointerType = event.pointer_type || event.pointerType || (event.type === "touch" ? "touch" : "mouse");
            const target = document.elementFromPoint(x, y);
            if (!target) return { delivered: false, error: "target_not_found" };
            if (typeof target.focus === "function") target.focus({ preventScroll: true });
            const options = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: Number(event.button || 0), pointerType };
            const fire = (name) => {
              const ctor = name.startsWith("pointer") && "PointerEvent" in window ? PointerEvent : MouseEvent;
              target.dispatchEvent(new ctor(name, options));
            };
            const sequences = {
              down: ["pointerdown", "mousedown"],
              up: ["pointerup", "mouseup"],
              move: ["pointermove", "mousemove"],
              click: ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]
            };
            (sequences[action] || sequences.click).forEach(fire);
            return { delivered: true, action, tag: target.tagName };
          }
        JS
      end
    end

    class Keyboard < RuntimeInputEvent
      private

      def function
        <<~JS.squish
          async () => {
            const event = #{payload_json};
            const target = document.activeElement || document.body;
            const action = event.action || "key_down";
            const eventName = action === "key_up" ? "keyup" : "keydown";
            const keyboardEvent = new KeyboardEvent(eventName, {
              bubbles: true,
              cancelable: true,
              composed: true,
              key: event.key || "",
              code: event.code || "",
              altKey: !!event.alt_key,
              ctrlKey: !!event.ctrl_key,
              metaKey: !!event.meta_key,
              shiftKey: !!event.shift_key,
              repeat: !!event.repeat
            });
            target.dispatchEvent(keyboardEvent);
            return { delivered: true, action, key: event.key || "", tag: target.tagName };
          }
        JS
      end
    end

    class Text < RuntimeInputEvent
      private

      def function
        <<~JS.squish
          async () => {
            const event = #{payload_json};
            const text = String(event.text || "");
            const target = document.activeElement;
            if (!target) return { delivered: false, error: "no_active_element" };
            if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
              const start = target.selectionStart ?? target.value.length;
              const end = target.selectionEnd ?? target.value.length;
              target.setRangeText(text, start, end, "end");
              target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
              return { delivered: true, action: "insert_text", tag: target.tagName };
            }
            if (target.isContentEditable) {
              document.execCommand("insertText", false, text);
              target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
              return { delivered: true, action: "insert_text", tag: target.tagName };
            }
            target.dispatchEvent(new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType: "insertText", data: text }));
            return { delivered: true, action: "text_event", tag: target.tagName };
          }
        JS
      end
    end

    class Unknown < RuntimeInputEvent
      def deliver(_session)
        { "result" => { "isError" => true, "content" => [ { "type" => "text", "text" => "unsupported_input_event: #{event['type']}" } ] } }
      end
    end
  end
end
