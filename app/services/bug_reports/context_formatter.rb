module BugReports
  module ContextFormatter
    # Opens the machine-appended section of a bug report body. Everything after
    # it is collected from the reporter's browser, not written by them.
    #
    # Shared rather than spelled out twice: PlannedExecutionRequestAnalyzer
    # excludes this section when inferring where work must run, because the
    # section quotes a User-Agent, and a User-Agent names the device it came
    # from. A report filed from a phone put the word "iphone" in the body and
    # the work was assigned to a macOS worker that does not exist. If this
    # heading changes and the analyzer is not updated with it, that failure
    # comes straight back.
    SECTION_DIVIDER = "---".freeze
    SECTION_HEADING = "**Environment**".freeze
    # Matches the divider and heading as a pair, so a divider the reporter
    # happened to type does not truncate what they wrote.
    SECTION_START = /^#{Regexp.escape(SECTION_DIVIDER)}[ \t]*\R#{Regexp.escape(SECTION_HEADING)}/i

    private

    def format_context_markdown(context_json)
      return "" if context_json.blank?

      context = context_json.is_a?(Hash) ? context_json : JSON.parse(context_json.to_s)

      lines = [ SECTION_DIVIDER, SECTION_HEADING ]
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
        acc[key] += error_occurrence_count(err["count"])
      end
    end

    def error_occurrence_count(raw_count)
      count = Integer(raw_count, exception: false)
      return 1 if count.nil? || count < 1
      count
    end
  end
end
