module ConnectedAccounts
  module OauthHttp
    module_function

    def post_form(url, fields)
      uri = URI.parse(url)
      response = Net::HTTP.post_form(uri, fields.compact)
      parse(response)
    end

    def get_json(url, access_token)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      parse(Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) })
    end

    def parse(response)
      retry_after = response["Retry-After"]&.to_i
      if response.code.to_i == 429
        raise Problem.new(code: "rate_limited", message: "OAuth provider rate limit reached", retry_after: retry_after)
      end
      unless response.is_a?(Net::HTTPSuccess)
        code = response.code.to_i == 403 ? "quota_exceeded" : "provider_error"
        raise Problem.new(code: code, message: "OAuth provider request failed", retry_after: retry_after)
      end
      body = JSON.parse(response.body.presence || "{}")
      body.deep_symbolize_keys
    rescue JSON::ParserError
      raise Problem.new(code: "invalid_provider_response", message: "OAuth provider returned an invalid response")
    end
  end
end
