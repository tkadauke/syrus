require "base64"
require "cgi"
require "net/http"

module GoogleWorkspace
  class MailAdapter
    API_ROOT = "https://gmail.googleapis.com/gmail/v1/users/me/".freeze
    MAX_BODY_BYTES = 1.megabyte
    ADDRESS_HEADERS = %w[From To Cc Bcc Reply-To].freeze

    class << self
      attr_writer :http

      def key = :google_workspace
      def display_name = "Gmail"
      def available_for?(context) = context.account.provider == "google_workspace"

      def search(context)
        return nil unless available_for?(context)

        limit = context.arguments.fetch("limit", 25).to_i.clamp(1, 100)
        payload = get(context, "messages", q: literal_query(context.arguments.fetch("query")), maxResults: limit)
        messages = Array(payload["messages"]).first(limit).map do |entry|
          normalize_message(get(context, "messages/#{escape_id(entry.fetch("id"))}", format: "metadata",
            metadataHeaders: %w[From To Cc Bcc Reply-To Subject Date]))
        end
        { "messages" => messages }
      end

      def read_message(context)
        return nil unless available_for?(context)

        normalize_message(get(context, "messages/#{escape_id(context.arguments.fetch("message_id"))}", format: "full"), body: true)
      end

      private

      # Gmail search has a rich operator language. Quoting and escaping the entire
      # caller value makes this adapter a literal text search rather than an
      # accidental way to add from:, OR, braces, or other operators.
      def literal_query(value) = "\"#{value.to_s.gsub(/([\\\"])/, '\\\\\1')}\""
      def escape_id(value) = ERB::Util.url_encode(value.to_s)

      def get(context, path, query = {})
        uri = URI.join(API_ROOT, path)
        uri.query = URI.encode_www_form(query) if query.any?
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = context.access.authorization_header
        response = (@http || Net::HTTP).start(uri.hostname, uri.port, use_ssl: true) { |client| client.request(request) }
        handle_response!(context.account, response)
        JSON.parse(response.body)
      rescue JSON::ParserError
        raise MailProblem.new(code: :invalid_response, message: "Gmail returned an invalid response")
      rescue Timeout::Error, SocketError, SystemCallError
        raise MailProblem.new(code: :temporarily_unavailable, message: "Gmail is temporarily unavailable")
      end

      def handle_response!(account, response)
        return if response.is_a?(Net::HTTPSuccess)

        if response.code.to_i == 401 || authorization_error?(response)
          ConnectedAccounts::OauthBroker.needs_reauth!(account)
          raise MailProblem.new(code: :needs_reauth, message: "The Google account must be reconnected")
        end
        if response.code.to_i == 429 || quota_error?(response)
          raise MailProblem.new(code: :quota_limited, message: "Gmail quota is temporarily unavailable",
            retry_after: response["Retry-After"])
        end
        raise MailProblem.new(code: :provider_error, message: "Gmail request failed (HTTP #{response.code})")
      end

      def authorization_error?(response) = response.code.to_i == 403 && error_reasons(response).intersect?(%w[authError invalidCredentials])
      def quota_error?(response) = response.code.to_i == 403 && error_reasons(response).intersect?(%w[rateLimitExceeded userRateLimitExceeded quotaExceeded])
      def error_reasons(response)
        Array(JSON.parse(response.body).dig("error", "errors")).filter_map { |entry| entry["reason"] }
      rescue JSON::ParserError
        []
      end

      def normalize_message(message, body: false)
        headers = header_map(message.dig("payload", "headers"))
        result = {
          "id" => message["id"], "thread_id" => message["threadId"], "sender" => headers["From"],
          "recipients" => recipient_headers(headers), "subject" => headers["Subject"], "date" => headers["Date"],
          "labels" => Array(message["labelIds"]), "snippet" => message["snippet"]
        }.compact
        return result unless body

        result["body"] = extract_body(message["payload"])
        attachments = attachment_metadata(message["payload"])
        result["attachments"] = attachments if attachments.any?
        result
      end

      def header_map(headers) = Array(headers).to_h { |header| [ header["name"], header["value"] ] }
      def recipient_headers(headers)
        ADDRESS_HEADERS.filter_map { |name| headers[name] unless name == "From" }.join(", ").presence
      end

      def extract_body(part)
        candidates = leaf_parts(part).reject { |leaf| leaf["filename"].present? }
        plain = candidates.select { |leaf| leaf["mimeType"].to_s.start_with?("text/plain") }
        html = candidates.select { |leaf| leaf["mimeType"].to_s.start_with?("text/html") }
        chosen = plain.presence || html
        text = chosen.to_a.filter_map { |leaf| decode_part(leaf) }.join("\n")
        text = html_to_text(text) if plain.blank? && html.present?
        truncate_body(text)
      end

      def leaf_parts(part)
        children = Array(part&.fetch("parts", nil))
        children.empty? ? (part ? [ part ] : []) : children.flat_map { |child| leaf_parts(child) }
      end

      def decode_part(part)
        encoded = part.dig("body", "data")
        return if encoded.blank?

        oversized = part.dig("body", "size").to_i > MAX_BODY_BYTES
        encoded = encoded.to_s.byteslice(0, ((MAX_BODY_BYTES + 2) / 3) * 4) if oversized
        bytes = Base64.urlsafe_decode64(encoded.to_s.ljust((encoded.length + 3) / 4 * 4, "="))
        content_type = Array(part["headers"]).find { |header| header["name"].to_s.casecmp?("Content-Type") }&.fetch("value", nil)
        charset = content_type.to_s[/charset\s*=\s*["']?([^;"']+)/i, 1] || part["mimeType"].to_s[/charset\s*=\s*["']?([^;"']+)/i, 1] || "UTF-8"
        decoded = bytes.force_encoding(charset).encode("UTF-8", invalid: :replace, undef: :replace)
        oversized ? "#{decoded}\n[Message body truncated]" : decoded
      rescue ArgumentError, EncodingError
        bytes.to_s.force_encoding("UTF-8").scrub
      end

      def html_to_text(value) = CGI.unescapeHTML(value.gsub(/<script\b[^>]*>.*?<\/script>/mi, " ").gsub(/<style\b[^>]*>.*?<\/style>/mi, " ").gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip)
      def truncate_body(value) = value.bytesize <= MAX_BODY_BYTES ? value : "#{value.byteslice(0, MAX_BODY_BYTES).to_s.force_encoding("UTF-8").scrub}\n[Message body truncated]"

      def attachment_metadata(part)
        leaf_parts(part).filter_map do |leaf|
          next if leaf["filename"].blank?

          { "filename" => leaf["filename"], "content_type" => leaf["mimeType"], "size" => leaf.dig("body", "size").to_i }.compact
        end
      end
    end
  end
end
