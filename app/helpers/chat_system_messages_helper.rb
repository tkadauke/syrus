module ChatSystemMessagesHelper
  SYSTEM_RESULT_PATTERN = /\A\[(?:codex )?result\]\s+(?<payload>.+)\z/
  SYSTEM_MCP_PATTERN = /\A\[mcp_servers\]\s+(?<payload>.+)\z/
  SYSTEM_CODEX_ERROR_PATTERN = /\A\[codex error\]\s+(?<message>.+)\z/

  def render_chat_system_message(text)
    message = chat_system_message(text.to_s)

    content_tag(:div, class: "flex justify-center") do
      content_tag(:div, class: chat_system_message_classes(message[:tone])) do
        safe_join([
          content_tag(:span, message[:label], class: chat_system_label_classes(message[:tone])),
          content_tag(:span, message[:body], class: "min-w-0 break-words")
        ], " ")
      end
    end
  end

  private

  def chat_system_message(raw)
    if (match = raw.match(SYSTEM_RESULT_PATTERN))
      chat_result_message(raw, parse_system_fields(match[:payload]))
    elsif (match = raw.match(SYSTEM_MCP_PATTERN))
      chat_mcp_message(raw, match[:payload])
    elsif (match = raw.match(SYSTEM_CODEX_ERROR_PATTERN))
      { raw: raw, tone: :error, label: "Error", body: match[:message].to_s }
    else
      { raw: raw, tone: :neutral, label: "System", body: raw }
    end
  end

  def chat_result_message(raw, fields)
    error = fields["is_error"].to_s == "true"
    subtype = fields["subtype"].to_s
    label = error ? "Failed" : "Done"
    body = [ chat_result_title(error, subtype) ]

    body << pluralize(fields["turns"].to_i, "turn") if fields["turns"].present?
    body << chat_duration_label(fields["duration_ms"]) if fields["duration_ms"].present?
    body << number_to_currency(fields["total_cost_usd"].to_f, precision: 2) if fields["total_cost_usd"].present?

    { raw: raw, tone: (error ? :error : :success), label: label, body: body.compact.join(" · ") }
  end

  def chat_result_title(error, subtype)
    return "Agent run failed#{": #{subtype.humanize}" if subtype.present?}" if error
    return "Agent run succeeded" if subtype == "success"

    subtype.present? ? "Agent run finished: #{subtype.humanize}" : "Agent run finished"
  end

  def chat_mcp_message(raw, payload)
    servers = payload.to_s.split(/\s*,\s*/).filter_map do |entry|
      name, status = entry.split("=", 2)
      next if name.blank?

      [ name, status.presence || "unknown" ]
    end

    failing = servers.reject { |_, status| chat_mcp_ok?(status) }
    tone = failing.any? ? :warning : :success
    label = failing.any? ? "MCP" : "Connected"
    body = if servers.empty?
      "MCP server status unavailable"
    elsif failing.any?
      "MCP issue: #{failing.map { |name, status| "#{name} #{status}" }.join(', ')}"
    else
      "MCP connected: #{servers.map(&:first).join(', ')}"
    end

    { raw: raw, tone: tone, label: label, body: body }
  end

  def chat_mcp_ok?(status)
    status.to_s.in?(%w[connected running ready])
  end

  def parse_system_fields(payload)
    payload.to_s.scan(/(\w+)=([^,\s]+)/).to_h
  end

  def chat_duration_label(duration_ms)
    seconds = duration_ms.to_f / 1000.0
    return "#{(seconds * 10).round / 10.0}s" if seconds < 60

    minutes = seconds / 60.0
    return "#{minutes.round(1)}m" if minutes < 10

    "#{minutes.round}m"
  end

  def chat_system_message_classes(tone)
    tone_classes = case tone
    when :success then "border-emerald-200 bg-emerald-50 text-emerald-900"
    when :warning then "border-amber-200 bg-amber-50 text-amber-900"
    when :error then "border-red-200 bg-red-50 text-red-900"
    else "border-gray-200 bg-gray-50 text-gray-600"
    end

    "inline-flex max-w-full items-center gap-2 rounded-full border px-3 py-1 text-xs not-italic #{tone_classes}"
  end

  def chat_system_label_classes(tone)
    tone_classes = case tone
    when :success then "bg-emerald-100 text-emerald-800"
    when :warning then "bg-amber-100 text-amber-800"
    when :error then "bg-red-100 text-red-800"
    else "bg-gray-100 text-gray-600"
    end

    "shrink-0 rounded px-1.5 py-0.5 font-medium uppercase tracking-wide #{tone_classes}"
  end
end
