require "uri"

module CredentialStore
  class Broker
    module TargetConstraint
      class AllowedUrlPrefixes < Base
        def satisfied?(target)
          target_uri = parse_http_url(target[:url], allow_query: true)
          target_uri.present? && values.any? { |prefix| prefix_matches?(target_uri, prefix) }
        end

        def denial_reason = "url not allowed"

        private

        def prefix_matches?(target_uri, prefix)
          prefix_uri = parse_http_url(prefix, allow_query: false)
          return false unless prefix_uri
          return false unless same_origin?(target_uri, prefix_uri)

          path_prefix?(target_uri.path, prefix_uri.path)
        end

        def parse_http_url(value, allow_query:)
          uri = URI.parse(value.to_s)
          return unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank?
          return if !allow_query && uri.query.present?
          return if uri.fragment.present?
          return if traversal_path?(uri.path)

          uri
        rescue URI::InvalidURIError
          nil
        end

        def same_origin?(left, right)
          left.scheme.casecmp?(right.scheme) &&
            normalized_host(left.host) == normalized_host(right.host) &&
            left.port == right.port
        end

        def normalized_host(host)
          host.to_s.downcase.delete_suffix(".")
        end

        def traversal_path?(path)
          return true if path.match?(/%25/i)

          decoded_path = path.gsub(/%(?:2e|2f|5c)/i) { |encoded| encoded.delete_prefix("%").to_i(16).chr }
          decoded_path.tr("\\", "/").split("/").intersect?([ ".", ".." ])
        end

        def path_prefix?(path, prefix)
          path = path.presence || "/"
          prefix = prefix.presence || "/"
          return true if prefix == "/"

          path == prefix || path.start_with?(prefix.end_with?("/") ? prefix : "#{prefix}/")
        end
      end
    end
  end
end
