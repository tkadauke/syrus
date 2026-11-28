require "mcp"
require "json"

module SyrusBrowser
  # Real Playwright pointer input at a viewport position, for Runtime panel
  # clicks on the streamed frame (the operator sees pixels, not snapshot
  # refs). It drives `page.mouse` (or `page.touchscreen` for touch) through
  # `browser_run_code_unsafe`, so it is native input like the target-based
  # tools, not a synthetic DOM event. Held modifier keys are pressed around
  # the click. Internal to runtime_input: not part of McpToolSet.
  class PointerAtTool < BrowserTool
    tool_name "browser_pointer_at"

    description "Click at a viewport position through Playwright's mouse (runtime_input only)."

    input_schema(
      type: "object",
      properties: {
        x: { type: "number" }, y: { type: "number" },
        normalized_x: { type: "number" }, normalized_y: { type: "number" },
        button: { type: "integer" }, pointer_type: { type: "string" },
        modifiers: { type: "array", items: { type: "string" } }
      }
    )

    proxies "browser_run_code_unsafe"
    requires_input_lease!

    MODIFIERS = %w[Alt Control Meta Shift].freeze
    BUTTONS = { 0 => "left", 1 => "middle", 2 => "right" }.freeze

    SCRIPT = <<~JS.freeze
      async (page) => {
        const input = %<input>s;
        let width = 0, height = 0;
        const size = page.viewportSize();
        if (size) { width = size.width; height = size.height; }
        else { const inner = await page.evaluate(() => [window.innerWidth, window.innerHeight]); width = inner[0]; height = inner[1]; }
        const useNormalized = Number.isFinite(input.normalized_x) && Number.isFinite(input.normalized_y) && width > 0 && height > 0;
        const x = useNormalized ? input.normalized_x * width : input.x;
        const y = useNormalized ? input.normalized_y * height : input.y;
        if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error("invalid_coordinates");
        for (const key of input.modifiers) await page.keyboard.down(key);
        try {
          if (input.pointer_type === "touch") {
            try { await page.touchscreen.tap(x, y); } catch (e) { await page.mouse.click(x, y, { button: input.button }); }
          } else {
            await page.mouse.click(x, y, { button: input.button });
          }
        } finally {
          for (const key of [...input.modifiers].reverse()) await page.keyboard.up(key);
        }
        return { delivered: true, x: Math.round(x), y: Math.round(y) };
      }
    JS

    class << self
      private

      def upstream_arguments(params)
        input = {
          x: finite(params[:x]), y: finite(params[:y]),
          normalized_x: finite(params[:normalized_x]), normalized_y: finite(params[:normalized_y]),
          button: BUTTONS.fetch(Integer(params[:button] || 0, exception: false) || 0, "left"),
          pointer_type: params[:pointer_type].to_s == "touch" ? "touch" : "mouse",
          modifiers: Array(params[:modifiers]).map(&:to_s) & MODIFIERS
        }
        { "code" => format(SCRIPT, input: JSON.generate(input)) }
      end

      def finite(value)
        number = Float(value, exception: false)
        number&.finite? ? number : nil
      end
    end
  end
end
