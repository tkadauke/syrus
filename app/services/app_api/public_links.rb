# frozen_string_literal: true

require "uri"

module AppApi
  class PublicLinks
    DEFAULT_DOCS_URL = "https://syrusai.dev/docs/getting-started"
    DEFAULT_EVALUATION_URL = "https://syrusai.dev/docs/deployment/try-it-locally"

    def self.docs_url
      public_url(ENV["SYRUS_DOCS_URL"], fallback: DEFAULT_DOCS_URL)
    end

    def self.evaluation_url
      public_url(ENV["SYRUS_EVALUATION_URL"], fallback: DEFAULT_EVALUATION_URL)
    end

    def self.public_url(value, fallback:)
      candidate = value.to_s.strip
      return fallback if candidate.blank?
      return candidate if root_relative_url?(candidate)

      uri = URI.parse(candidate)
      return candidate if uri.is_a?(URI::HTTP) && uri.host.present?

      fallback
    rescue URI::InvalidURIError
      fallback
    end
    private_class_method :public_url

    def self.root_relative_url?(value)
      value.start_with?("/") && !value.start_with?("//")
    end
    private_class_method :root_relative_url?
  end
end
