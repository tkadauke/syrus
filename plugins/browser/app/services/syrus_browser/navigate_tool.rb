require "mcp"

module SyrusBrowser
  class NavigateTool < BrowserTool
    tool_name "browser_navigate"

    description "Navigate the headless browser to a URL. Restricted to the worker's own " \
                "loopback preview (127.0.0.1/localhost, as started by start_preview) — any " \
                "other host is rejected before the browser is touched."

    input_schema(
      type: "object",
      properties: {
        url: { type: "string", description: "URL to navigate to, e.g. http://127.0.0.1:3001/dashboard" }
      },
      required: [ "url" ]
    )

    proxies "browser_navigate", url: "url"

    class << self
      def call(server_context:, **params)
        url = params[:url]
        return error("url is required") if url.blank?

        unless LoopbackGuard.allowed?(url)
          return error(
            "Navigation to #{url.inspect} was blocked: the browser tool set can only reach the " \
            "worker's own loopback preview (http://127.0.0.1:<port> or http://localhost:<port>)."
          )
        end

        super
      end
    end
  end
end
