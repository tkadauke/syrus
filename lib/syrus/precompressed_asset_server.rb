require "digest"
require "pathname"
require "rack/mime"

module Syrus
  class PrecompressedAssetServer
    ENCODINGS = [
      { name: "br", extension: ".br" },
      { name: "gzip", extension: ".gz" }
    ].freeze

    def initialize(app, root:, prefix:, headers: {})
      @app = app
      @root = Pathname.new(root)
      @prefix = prefix.to_s.end_with?("/") ? prefix.to_s : "#{prefix}/"
      @headers = headers.to_h
    end

    def call(env)
      request = Rack::Request.new(env)
      return @app.call(env) unless request.get? || request.head?
      return @app.call(env) unless request.path_info.start_with?(@prefix)

      relative_path = Rack::Utils.unescape_path(request.path_info.delete_prefix("/"))
      return @app.call(env) if unsafe_path?(relative_path)

      plain_path = @root.join(relative_path)
      response_asset = response_asset_for(plain_path, env["HTTP_ACCEPT_ENCODING"].to_s)
      return @app.call(env) unless response_asset

      headers = response_headers(plain_path, response_asset)
      body = request.head? ? [] : [ response_asset.fetch(:path).binread ]

      [ 200, headers, body ]
    end

    private
      def unsafe_path?(relative_path)
        relative_path.empty? || relative_path.split("/").include?("..")
      end

      def response_asset_for(plain_path, accept_encoding)
        ENCODINGS.each do |encoding|
          next unless accepts_encoding?(accept_encoding, encoding.fetch(:name))

          path = Pathname.new("#{plain_path}#{encoding.fetch(:extension)}")
          return { encoding: encoding.fetch(:name), path: path } if path.file?
        end

        { encoding: nil, path: plain_path } if plain_path.file?
      end

      def accepts_encoding?(accept_encoding, encoding)
        accept_encoding.split(",").any? do |entry|
          name, *parameters = entry.strip.split(";").map(&:strip)
          next false unless name == encoding || name == "*"

          q = parameters.find { |parameter| parameter.start_with?("q=") }&.delete_prefix("q=")&.to_f
          q.nil? || q.positive?
        end
      end

      def response_headers(plain_path, variant)
        encoded_path = variant.fetch(:path)
        @headers.merge(
          Rack::CONTENT_TYPE => Rack::Mime.mime_type(plain_path.extname, "application/octet-stream"),
          Rack::CONTENT_LENGTH => encoded_path.size.to_s,
          Rack::ETAG => %("#{Digest::SHA256.file(encoded_path).hexdigest}"),
          "Vary" => "Accept-Encoding"
        ).tap do |headers|
          headers["Content-Encoding"] = variant.fetch(:encoding) if variant.fetch(:encoding)
        end
      end
  end
end
