require "mcp"
require "json"
require "base64"

module SyrusBrowser
  # Base class for granular browser-control MCP tools (see McpToolSet).
  # Most tools are thin proxies to the per-Run @playwright/mcp subprocess:
  # a subclass declares `proxies upstream_tool_name, our_key => upstream_key`
  # and inherits .call, which forwards the request to the Run's browser
  # Session and translates the response back into our own tool-name/argument
  # surface. browser_navigate and browser_close override .call for their own
  # local behavior (loopback guard / session teardown) but still reuse the
  # shared ok/error helpers here.
  class BrowserTool < MCP::Tool
    class << self
      attr_accessor :upstream_tool_name, :argument_key_map, :argument_alias_map

      def proxies(upstream_tool_name, argument_key_map = {})
        self.upstream_tool_name = upstream_tool_name
        self.argument_key_map = argument_key_map
      end

      def argument_aliases(argument_alias_map = {})
        self.argument_alias_map = argument_alias_map
      end

      # Opt-in flag for tools whose upstream response can carry captured
      # evidence (image content blocks) that should be routed through the
      # call's ArtifactSink -- see #translate. Most proxied tools (click,
      # fill, navigate, ...) have nothing to capture and leave this false.
      def captures_artifact!
        @captures_artifact = true
      end

      def captures_artifact?
        !!@captures_artifact
      end

      # Opt-in flag for tools that deliver real pointer/keyboard input to a
      # shared Runtime Session (DOC-17's Shared Human/Agent Control) -- click,
      # fill, hover. These are the only working way to drive pointer/keyboard
      # input today (RuntimeSessionProvider#input itself still answers
      # "not_yet_supported"), so without this check an agent could bypass the
      # runtime_acquire_control lease entirely by calling these tools
      # directly instead of going through runtime_input. Navigate/resize/
      # close/snapshot/screenshot/wait_for stay ungated: navigation is also
      # how runtime_launch drives the initial page load (which must not
      # itself require a pre-acquired lease), and the rest are observational
      # or session-lifecycle actions, not "input" in DOC-17's capability
      # sense. Enforcement only applies when the call targets an actual
      # RuntimeSession (a Coding Mode chat) -- the workflow Run path
      # (visual_review) has no lease concept and is unaffected.
      def requires_input_lease!
        @requires_input_lease = true
      end

      def requires_input_lease?
        !!@requires_input_lease
      end

      def call(server_context:, **params)
        params = normalize_argument_aliases(params)
        missing = missing_required_arguments(params)
        return error(missing_arguments_message(missing)) if missing.any?

        context = SessionContext.resolve(server_context)
        lease_error = enforce_input_lease(context)
        return lease_error if lease_error

        session = SessionRegistry.fetch(context.session_key)
        response = session.call_tool(name: upstream_tool_name, arguments: upstream_arguments(params))
        translate(response, artifact_sink: context.artifact_sink)
      rescue SessionContext::NoActiveSessionError => e
        error(e.message)
      rescue MCP::Client::ServerError => e
        error("browser tool #{tool_name} failed: #{e.message}")
      rescue StandardError => e
        error("#{e.class}: #{e.message}")
      end

      def ok(data)
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(data) } ])
      end

      def error(message)
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{message}" } ], error: true)
      end

      private

      # Returns an error Response when this tool requires an input lease and
      # the calling RuntimeSession's agent does not currently hold one; nil
      # (proceed) otherwise, including for any call that does not target a
      # RuntimeSession at all (the workflow Run path).
      def enforce_input_lease(context)
        return nil unless requires_input_lease?

        runtime_session = context.owner
        return nil unless runtime_session.is_a?(RuntimeSession)
        return nil if runtime_session.active_agent_input_lease

        RuntimeControlLease.audit_input_rejected!(runtime_session: runtime_session, event: { tool: tool_name })
        error(
          "lease_required: the agent must hold an active runtime_acquire_control(mode: \"input\") " \
          "lease on this Runtime Session before calling #{tool_name}."
        )
      end

      def missing_required_arguments(params)
        required = Array(input_schema_value.to_h.dig(:required))
        required.select do |key|
          value = params[key.to_sym]
          value.nil? || (value.respond_to?(:blank?) ? value.blank? : value.to_s.empty?)
        end
      end

      def missing_arguments_message(keys)
        "browser tool #{tool_name} requires #{keys.join(", ")}. " \
          "Call browser_snapshot first, then pass the exact target/ref from the snapshot; " \
          "do not invent selectors or pass undefined targets."
      end

      def upstream_arguments(params)
        argument_key_map.each_with_object({}) do |(our_key, upstream_key), arguments|
          arguments[upstream_key] = params[our_key] if params.key?(our_key)
        end
      end

      def normalize_argument_aliases(params)
        normalized = params.dup
        argument_alias_map.to_h.each do |canonical_key, aliases|
          canonical = canonical_key.to_sym
          next if present_argument?(normalized[canonical])

          Array(aliases).each do |alias_key|
            value = normalized[alias_key.to_sym]
            next unless present_argument?(value)

            normalized[canonical] = value
            break
          end
        end
        normalized
      end

      def present_argument?(value)
        !(value.nil? || (value.respond_to?(:blank?) ? value.blank? : value.to_s.empty?))
      end

      def translate(response, artifact_sink: nil)
        result = response.is_a?(Hash) ? response["result"] : nil
        content = result.is_a?(Hash) ? Array(result["content"]) : []
        content = content.map { |block| block.is_a?(Hash) ? block.transform_keys(&:to_sym) : block }
        err = result.is_a?(Hash) && result["isError"] == true

        capture_artifacts!(content, artifact_sink) if captures_artifact? && artifact_sink && !err

        MCP::Tool::Response.new(content.presence || [ { type: "text", text: "" } ], error: err)
      end

      # Best-effort: a capture failure must never turn a successful browser
      # action into a tool error -- the agent already got its response.
      def capture_artifacts!(content, artifact_sink)
        content.each do |block|
          next unless block.is_a?(Hash) && block[:type] == "image" && block[:data].present?

          artifact_sink.capture(
            bytes: Base64.decode64(block[:data].to_s),
            content_type: block[:mimeType].presence || "image/png",
            title: "#{tool_name} capture"
          )
        end
      rescue StandardError => e
        Rails.logger.warn("[SyrusBrowser::BrowserTool] artifact capture failed: #{e.class}: #{e.message}")
      end
    end
  end
end
