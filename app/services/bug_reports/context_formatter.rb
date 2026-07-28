module BugReports
  module ContextFormatter
    private

    def format_context_markdown(context_json)
      return "" if context_json.blank?

      context = JSON.parse(context_json.to_s)

      lines = [ "---", "**Environment**" ]
      lines << "- URL: #{context["url"]}" if context["url"].present?
      lines << "- Browser: #{context["user_agent"]}" if context["user_agent"].present?

      if (vp = context["viewport"]).is_a?(Hash) && vp["width"] && vp["height"]
        dpr = context["device_pixel_ratio"]
        lines << "- Viewport: #{vp["width"]}×#{vp["height"]}#{dpr ? " @ #{dpr}x" : ""}"
      end

      lines << "- Chat session: #{context["chat_session_id"]}" if context["chat_session_id"].present?

      recent_errors = Array(context["recent_errors"]).select { |e| e.is_a?(Hash) }
      if recent_errors.any?
        lines << ""
        lines << "**Recent JS errors**"
        recent_errors.each do |err|
          message = err["message"].to_s.gsub("`", "'")
          source  = err["source"].to_s
          lines << "- `#{message}` (#{source})"
        end
      end

      "\n\n" + lines.join("\n")
    rescue JSON::ParserError
      ""
    end
  end
end
