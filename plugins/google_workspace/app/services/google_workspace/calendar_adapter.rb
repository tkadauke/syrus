require "net/http"

module GoogleWorkspace
  class CalendarAdapter
    API_ROOT = "https://www.googleapis.com/calendar/v3/".freeze

    class << self
      attr_writer :http

      def key = :google_workspace
      def display_name = "Google Calendar"
      def available_for?(context) = context.account.provider == "google_workspace"

      def list_events(context)
        return nil unless available_for?(context)

        arguments = context.arguments
        limit = arguments.fetch("limit", 25).to_i.clamp(1, 100)
        events = []
        page_token = nil
        loop do
          query = {
            singleEvents: true,
            orderBy: "startTime",
            timeMin: Time.iso8601(arguments.fetch("starts_at")).iso8601,
            timeMax: Time.iso8601(arguments.fetch("ends_at")).iso8601,
            maxResults: [ limit - events.length, 100 ].min
          }
          query[:pageToken] = page_token if page_token.present?
          payload = get(context, "calendars/primary/events", query)
          events.concat(Array(payload["items"]).map { |event| normalize_event(event) })
          page_token = payload["nextPageToken"]
          break if page_token.blank? || events.length >= limit
        end
        { "events" => events.first(limit) }
      rescue ArgumentError => error
        raise CalendarProblem.new(code: :invalid_time_range, message: error.message)
      end

      def get_event(context)
        return nil unless available_for?(context)

        event_id = ERB::Util.url_encode(context.arguments.fetch("event_id"))
        { "event" => normalize_event(get(context, "calendars/primary/events/#{event_id}")) }
      end

      private

      def get(context, path, query = {})
        uri = URI.join(API_ROOT, path)
        uri.query = URI.encode_www_form(query) if query.any?
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = context.access.authorization_header
        response = (@http || Net::HTTP).start(uri.hostname, uri.port, use_ssl: true) { |client| client.request(request) }
        handle_response!(context.account, response)
        JSON.parse(response.body)
      rescue JSON::ParserError
        raise CalendarProblem.new(code: :invalid_response, message: "Google Calendar returned an invalid response")
      rescue Timeout::Error, SocketError, SystemCallError
        raise CalendarProblem.new(code: :temporarily_unavailable, message: "Google Calendar is temporarily unavailable")
      end

      def handle_response!(account, response)
        return if response.is_a?(Net::HTTPSuccess)

        if response.code.to_i == 401 || authorization_error?(response)
          ConnectedAccounts::OauthBroker.needs_reauth!(account)
          raise CalendarProblem.new(code: :needs_reauth, message: "The Google account must be reconnected")
        end
        if response.code.to_i == 429 || quota_error?(response)
          raise CalendarProblem.new(code: :quota_limited, message: "Google Calendar quota is temporarily unavailable",
            retry_after: response["Retry-After"])
        end
        raise CalendarProblem.new(code: :provider_error, message: "Google Calendar request failed (HTTP #{response.code})")
      end

      def authorization_error?(response) = response.code.to_i == 403 && error_reasons(response).intersect?(%w[authError invalidCredentials])
      def quota_error?(response) = response.code.to_i == 403 && error_reasons(response).intersect?(%w[rateLimitExceeded userRateLimitExceeded quotaExceeded])
      def error_reasons(response)
        Array(JSON.parse(response.body).dig("error", "errors")).filter_map { |entry| entry["reason"] }
      rescue JSON::ParserError
        []
      end

      def normalize_event(event)
        start_value = normalize_time(event["start"])
        end_value = normalize_time(event["end"])
        {
          "id" => event["id"],
          "title" => event["summary"],
          "description" => event["description"],
          "location" => event["location"],
          "status" => event["status"],
          "html_url" => event["htmlLink"],
          "recurring_event_id" => event["recurringEventId"],
          "start" => start_value,
          "end" => end_value,
          "time_zone" => event.dig("start", "timeZone") || event.dig("end", "timeZone"),
          "all_day" => event.dig("start", "date").present?
        }.compact
      end

      def normalize_time(value)
        return unless value

        value["dateTime"] || value["date"]
      end
    end
  end
end
