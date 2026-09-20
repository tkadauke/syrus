module BugReports
  module ContextFormatter
    private

    def format_context_markdown(context_json)
      return "" if context_json.blank?

      context = context_json.is_a?(Hash) ? context_json : JSON.parse(context_json.to_s)

      lines = [ "---", "**Environment**" ]
      lines << "- URL: #{context["url"]}" if context["url"].present?
      lines << "- Browser: #{context["user_agent"]}" if context["user_agent"].present?

      if (vp = context["viewport"]).is_a?(Hash) && vp["width"] && vp["height"]
        dpr = context["device_pixel_ratio"]
        lines << "- Viewport: #{vp["width"]}×#{vp["height"]}#{dpr ? " @ #{dpr}x" : ""}"
      end

      lines << "- Chat session: #{context["chat_session_id"]}" if context["chat_session_id"].present?

      enabled_features = context["enabled_features"]
      if enabled_features.is_a?(Hash) && enabled_features.any?
        lines << ""
        lines << "**Feature flags**"
        enabled_features.sort_by { |slug, _| slug }.each do |slug, enabled|
          lines << "- #{slug}: #{enabled ? "enabled" : "disabled"}"
        end
      end

      recent_errors = Array(context["recent_errors"]).select { |e| e.is_a?(Hash) }
      if recent_errors.any?
        lines << ""
        lines << "**Recent JS errors**"
        deduped_errors(recent_errors).each do |(message, source), count|
          suffix = count > 1 ? " (×#{count})" : ""
          lines << "- `#{message.gsub("`", "'")}` (#{source})#{suffix}"
        end
      end

      "\n\n" + lines.join("\n")
    rescue JSON::ParserError
      ""
    end

    def deduped_errors(recent_errors)
      recent_errors.each_with_object({}) do |err, acc|
        key = [ err["message"].to_s, err["source"].to_s ]
        acc[key] ||= 0
        acc[key] += err["count"].to_i.nonzero? || 1
      end
    end
  end
end
