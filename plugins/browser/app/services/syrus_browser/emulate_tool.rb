require "mcp"
require "json"
require "base64"

module SyrusBrowser
  # browser_emulate: device/viewport/media emulation beyond browser_resize.
  #
  # @playwright/mcp has no emulation tool, but it exposes
  # `browser_run_code_unsafe`, which runs a function against the Playwright
  # `page`. This tool builds such a function: it opens one CDP session per page
  # (kept on the page object so the overrides stay attached -- CDP overrides
  # are dropped when their session detaches) and applies
  # Emulation.setDeviceMetricsOverride / setTouchEmulationEnabled /
  # setUserAgentOverride / setSafeAreaInsetsOverride plus page.emulateMedia.
  # CDP overrides are per-target, so they survive navigation and reloads. The
  # merged state is kept on the page too, which is what makes unspecified
  # fields "unchanged". Both the stdio and the runtime-service transports
  # reach the same upstream tool, so they behave identically.
  class EmulateTool < BrowserTool
    tool_name "browser_emulate"

    UPSTREAM_TOOL = "browser_run_code_unsafe".freeze
    STATE_MARKER = "SYRUS_EMULATION_B64:".freeze
    COLOR_SCHEMES = %w[light dark].freeze
    MAX_DIMENSION = 10_000
    MAX_INSET = 1_000
    MAX_SCALE_FACTOR = 10
    MAX_USER_AGENT_LENGTH = 1_000
    INSET_SIDES = %w[top right bottom left].freeze

    description "Emulate a device in the browser: a named preset (iphone-15-pro, desktop), viewport, " \
                "device scale factor, mobile/touch, user agent, safe-area insets (env(safe-area-inset-*)), " \
                "color scheme and reduced motion. All fields are optional; unspecified fields keep their " \
                "current value, and explicit fields override the preset. preset \"desktop\" fully resets " \
                "emulation. Chromium only. Re-run browser_snapshot afterwards."

    input_schema(
      type: "object",
      properties: {
        preset: { type: "string", enum: EmulationPresets.names, description: "Named device profile." },
        viewport: {
          type: "object",
          properties: { width: { type: "integer" }, height: { type: "integer" } },
          description: "Viewport size in CSS pixels."
        },
        device_scale_factor: { type: "number", description: "Device pixel ratio, e.g. 3." },
        is_mobile: { type: "boolean", description: "Emulate a mobile device (meta viewport, overlay scrollbars)." },
        has_touch: { type: "boolean", description: "Emulate touch input." },
        user_agent: { type: "string", description: "User agent string; empty string restores the default." },
        safe_area_insets: {
          type: "object",
          properties: {
            top: { type: "number" }, right: { type: "number" }, bottom: { type: "number" }, left: { type: "number" }
          },
          description: "env(safe-area-inset-*) values in CSS pixels."
        },
        color_scheme: { type: "string", enum: COLOR_SCHEMES, description: "prefers-color-scheme." },
        reduced_motion: { type: "boolean", description: "prefers-reduced-motion: reduce when true." }
      }
    )

    APPLY_SCRIPT = <<~JS.freeze
      async (page) => {
        const patch = %<patch>s;
        const state = page.__syrusEmulation || { viewport: { width: 1280, height: 720 }, device_scale_factor: 1,
          is_mobile: false, has_touch: false, user_agent: "", safe_area_insets: { top: 0, right: 0, bottom: 0, left: 0 },
          color_scheme: null, reduced_motion: null };
        // browser_resize changes the viewport behind our back; trust the page's current size so
        // fields the caller did not specify (including the viewport) stay unchanged.
        const current = page.viewportSize();
        if (current) state.viewport = { width: current.width, height: current.height };
        for (const key of Object.keys(patch)) {
          const value = patch[key];
          state[key] = (value && typeof value === "object") ? Object.assign({}, state[key], value) : value;
        }
        let cdp = page.__syrusCdp;
        if (!cdp) {
          try {
            cdp = await page.context().newCDPSession(page);
          } catch (e) {
            throw new Error("CDP emulation is unsupported by this browser (Chromium required): " + e.message);
          }
          page.__syrusCdp = cdp;
        }
        await page.setViewportSize({ width: state.viewport.width, height: state.viewport.height });
        await cdp.send("Emulation.setDeviceMetricsOverride", {
          width: state.viewport.width, height: state.viewport.height,
          deviceScaleFactor: state.device_scale_factor, mobile: state.is_mobile
        });
        await cdp.send("Emulation.setTouchEmulationEnabled", state.has_touch ? { enabled: true, maxTouchPoints: 5 } : { enabled: false });
        await cdp.send("Emulation.setUserAgentOverride", { userAgent: state.user_agent });
        await cdp.send("Emulation.setSafeAreaInsetsOverride", { insets: state.safe_area_insets });
        await page.emulateMedia({
          colorScheme: state.color_scheme,
          reducedMotion: state.reduced_motion === null ? null : (state.reduced_motion ? "reduce" : "no-preference")
        });
        page.__syrusEmulation = state;
        return "%<marker>s" + Buffer.from(JSON.stringify(state)).toString("base64");
      }
    JS

    class InvalidArguments < StandardError; end

    class << self
      def call(server_context:, **params)
        patch = build_patch(params)
        context = SessionContext.resolve(server_context)
        session = SessionRegistry.fetch(context.session_key)
        response = session.call_tool(name: UPSTREAM_TOOL, arguments: { "code" => script_for(patch) })
        result = translate(response)
        return result if result.error?

        state = extract_state(result)
        return error("browser_emulate could not confirm the emulation state; the browser did not run it") unless state

        MCP::Tool::Response.new([ { type: "text", text: summarize(state) } ])
      rescue InvalidArguments => e
        error(e.message)
      rescue SessionContext::NoActiveSessionError => e
        error(e.message)
      rescue MCP::Client::ServerError => e
        error("browser tool #{tool_name} failed: #{e.message}")
      rescue StandardError => e
        error("#{e.class}: #{e.message}")
      end

      # Resolves preset + explicit fields into the patch applied on top of the
      # page's current state. Explicit fields win over the preset; nested
      # hashes (viewport, safe_area_insets) merge key by key.
      def build_patch(params)
        params = params.transform_keys(&:to_sym)
        patch = {}
        preset = params[:preset]
        if present?(preset)
          raise InvalidArguments, "unknown preset #{preset.inspect}; expected one of #{EmulationPresets.names.join(", ")}" unless EmulationPresets.names.include?(preset.to_s)

          patch = deep_dup(EmulationPresets.fetch(preset))
        end

        explicit_fields(params).each do |key, value|
          patch[key] = value.is_a?(Hash) ? (patch[key] || {}).merge(value) : value
        end
        raise InvalidArguments, "browser_emulate needs at least one field (preset, viewport, ...)" if patch.empty?

        patch
      end

      private

      def explicit_fields(params)
        fields = {}
        fields[:viewport] = dimensions(params[:viewport], %i[width height], "viewport", 1, MAX_DIMENSION, integer: true) unless params[:viewport].nil?
        unless params[:device_scale_factor].nil?
          fields[:device_scale_factor] = number(params[:device_scale_factor], "device_scale_factor", 0.1, MAX_SCALE_FACTOR)
        end
        fields[:is_mobile] = boolean(params[:is_mobile], "is_mobile") unless params[:is_mobile].nil?
        fields[:has_touch] = boolean(params[:has_touch], "has_touch") unless params[:has_touch].nil?
        unless params[:user_agent].nil?
          raise InvalidArguments, "user_agent must be a string up to #{MAX_USER_AGENT_LENGTH} characters" unless params[:user_agent].is_a?(String) && params[:user_agent].length <= MAX_USER_AGENT_LENGTH

          fields[:user_agent] = params[:user_agent]
        end
        unless params[:safe_area_insets].nil?
          fields[:safe_area_insets] = dimensions(params[:safe_area_insets], INSET_SIDES.map(&:to_sym), "safe_area_insets", 0, MAX_INSET, integer: false)
        end
        unless params[:color_scheme].nil?
          raise InvalidArguments, "color_scheme must be one of #{COLOR_SCHEMES.join(", ")}" unless COLOR_SCHEMES.include?(params[:color_scheme].to_s)

          fields[:color_scheme] = params[:color_scheme].to_s
        end
        fields[:reduced_motion] = boolean(params[:reduced_motion], "reduced_motion") unless params[:reduced_motion].nil?
        fields
      end

      def dimensions(value, keys, label, min, max, integer:)
        raise InvalidArguments, "#{label} must be an object" unless value.respond_to?(:to_h) && !value.is_a?(Array)

        hash = value.to_h.transform_keys(&:to_sym)
        raise InvalidArguments, "#{label} needs at least one of #{keys.join(", ")}" if (hash.keys & keys).empty?

        (hash.keys & keys).each_with_object({}) do |key, out|
          out[key] = integer ? integer_in(hash[key], "#{label}.#{key}", min, max) : number(hash[key], "#{label}.#{key}", min, max)
        end
      end

      def integer_in(value, label, min, max)
        number = number(value, label, min, max)
        raise InvalidArguments, "#{label} must be an integer" unless number == number.to_i

        number.to_i
      end

      def number(value, label, min, max)
        raise InvalidArguments, "#{label} must be a number between #{min} and #{max}" unless value.is_a?(Numeric) && value.to_f.finite? && value >= min && value <= max

        value
      end

      def boolean(value, label)
        raise InvalidArguments, "#{label} must be true or false" unless [ true, false ].include?(value)

        value
      end

      def present?(value)
        !(value.nil? || value.to_s.empty?)
      end

      def deep_dup(hash)
        hash.transform_values { |value| value.is_a?(Hash) ? value.dup : value }
      end

      def script_for(patch)
        # JSON is valid JS; escape U+2028/2029 which JSON allows but old JS does not.
        json = JSON.generate(patch).gsub("\u2028", "\\u2028").gsub("\u2029", "\\u2029")
        format(APPLY_SCRIPT, patch: json, marker: STATE_MARKER)
      end

      def extract_state(response)
        text = response.content.map { |block| block[:text].to_s }.join("\n")
        encoded = text[/#{Regexp.escape(STATE_MARKER)}([A-Za-z0-9+\/=]+)/, 1]
        encoded && JSON.parse(Base64.decode64(encoded))
      rescue JSON::ParserError
        nil
      end

      def summarize(state)
        viewport = state["viewport"]
        insets = state["safe_area_insets"]
        [
          "Emulation applied.",
          "viewport #{viewport["width"]}x#{viewport["height"]} @#{state["device_scale_factor"]}x",
          "mobile=#{state["is_mobile"]} touch=#{state["has_touch"]}",
          "safe-area top=#{insets["top"]} right=#{insets["right"]} bottom=#{insets["bottom"]} left=#{insets["left"]}",
          "color_scheme=#{state["color_scheme"] || "default"}",
          "reduced_motion=#{state["reduced_motion"].nil? ? "default" : state["reduced_motion"]}",
          "user_agent=#{state["user_agent"].to_s.empty? ? "default" : state["user_agent"]}"
        ].join("; ") + ". Re-run browser_snapshot before interacting."
      end
    end
  end
end
