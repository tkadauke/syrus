class GithubAppClient
  API_ROOT = "https://api.github.com".freeze
  USER_AGENT = GithubClient::USER_AGENT

  def self.manifest_conversion(code)
    response = Faraday.post("#{API_ROOT}/app-manifests/#{code}/conversions") do |req|
      req.headers["Accept"] = "application/vnd.github+json"
      req.headers["User-Agent"] = USER_AGENT
      req.headers["X-GitHub-Api-Version"] = "2022-11-28"
    end
    raise Octokit::Error.from_response(response) unless response.success?
    JSON.parse(response.body)
  end

  def self.installations
    settings = AppSetting.current
    return [] unless settings.github_app_registered?

    client = Octokit::Client.new(
      bearer_token: app_jwt(settings),
      user_agent: USER_AGENT,
      auto_paginate: true
    )
    client.find_app_installations
  end

  def self.app_jwt(settings = AppSetting.current, now: Time.current)
    header = { alg: "RS256", typ: "JWT" }
    payload = {
      iat: now.to_i - 60,
      exp: now.to_i + 9.minutes.to_i,
      iss: settings.github_app_id
    }
    signing_input = [ header, payload ].map { |part| base64url(JSON.generate(part)) }.join(".")
    key = OpenSSL::PKey::RSA.new(settings.github_app_private_key_pem)
    signature = key.sign(OpenSSL::Digest::SHA256.new, signing_input)
    "#{signing_input}.#{base64url(signature)}"
  end

  def self.base64url(value)
    Base64.urlsafe_encode64(value, padding: false)
  end
  private_class_method :base64url
end
