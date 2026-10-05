require "open3"
require "pathname"
require "zlib"

module Syrus
  class PrecompressedAssetBuilder
    COMPRESSIBLE_EXTENSIONS = %w[.css .html .js .json .map .svg .txt .xml].freeze

    def initialize(output_path:)
      @output_path = Pathname.new(output_path)
    end

    def call
      return [] unless output_path.directory?

      compressible_assets.flat_map do |path|
        [
          write_brotli(path),
          write_gzip(path)
        ].compact
      end
    end

    private
      attr_reader :output_path

      def compressible_assets
        output_path.glob("**/*").select do |path|
          path.file? &&
            COMPRESSIBLE_EXTENSIONS.include?(path.extname) &&
            !path.to_s.end_with?(".br", ".gz")
        end
      end

      def write_brotli(path)
        return unless brotli_available?

        target = Pathname.new("#{path}.br")
        command = brotli_command(path, target)
        _stdout, stderr, status = Open3.capture3(*command)
        raise "brotli failed for #{path}: #{stderr}" unless status.success?

        target
      end

      def write_gzip(path)
        target = Pathname.new("#{path}.gz")
        Zlib::GzipWriter.open(target.to_s, Zlib::BEST_COMPRESSION) do |gzip|
          gzip.mtime = path.mtime.to_i
          gzip.orig_name = path.basename.to_s
          gzip.write(path.binread)
        end
        target
      end

      def brotli_available?
        @brotli_available = brotli_command_available? || node_brotli_available? if @brotli_available.nil?
        @brotli_available
      end

      def brotli_command(path, target)
        if brotli_command_available?
          [ "brotli", "--quality=11", "--force", "--output=#{target}", path.to_s ]
        else
          [
            "node",
            "-e",
            <<~JS,
              const fs = require("fs");
              const zlib = require("zlib");
              const [input, output] = process.argv.slice(1);
              const data = fs.readFileSync(input);
              const encoded = zlib.brotliCompressSync(data, {
                params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 }
              });
              fs.writeFileSync(output, encoded);
            JS
            path.to_s,
            target.to_s
          ]
        end
      end

      def brotli_command_available?
        @brotli_command_available = system("brotli", "--version", out: File::NULL, err: File::NULL) if @brotli_command_available.nil?
        @brotli_command_available
      end

      def node_brotli_available?
        @node_brotli_available = system(
          "node",
          "-e",
          "require('zlib').brotliCompressSync(Buffer.from('ok'))",
          out: File::NULL,
          err: File::NULL
        ) if @node_brotli_available.nil?
        @node_brotli_available
      end
  end
end
