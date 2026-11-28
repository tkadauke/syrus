require "json"
require "pathname"

module Syrus
  # How much the SPA shell has to download before React can render, so the
  # startup screen can show real progress on a slow connection instead of an
  # open-ended spinner.
  #
  # The set is the Vite entry plus its static imports (ViteEntrypoint#
  # startup_files) and every stylesheet the shell links. Each file has two
  # sizes:
  #
  # - its uncompressed size on disk, which is what the service worker counts as
  #   the decoded body streams past;
  # - its size on the wire: the precompressed variant
  #   (Syrus::PrecompressedAssetBuilder) the browser will be served for its
  #   Accept-Encoding, by the rule Syrus::PrecompressedAssetServer applies.
  #
  # The page shows progress, speed and time left in wire bytes, so the total and
  # the speed are what actually crosses the network.
  class StartupAssets
    STARTUP_GZIP_BUDGET_BYTES = 480_000
    # Which file each encoding is stored in, in the server's order of
    # preference: Brotli when the browser takes it and the build made one, else
    # gzip, else the plain file.
    ENCODINGS = { "br" => ".br", "gzip" => ".gz" }.freeze

    # sizes: { "/assets/<file>" => uncompressed bytes }
    # variants: { "/assets/<file>" => { "br" => bytes, "gzip" => bytes } }, for
    # the variants the build wrote.
    Result = Data.define(:sizes, :variants, :lazy_chunks) do
      # What the meta tag carries for one request. With no Accept-Encoding to
      # go by (something in between may have stripped it), each file is
      # assumed to arrive as its smallest variant and the total is marked as an
      # estimate.
      def for_request(accept_encoding)
        known = accept_encoding.to_s.strip.present?
        assets = sizes.to_h do |path, size|
          asset = { "size" => size, "wire" => wire_size(path, size, known ? accept_encoding : nil) }
          asset["budget"] = variants.fetch(path, {}).fetch("gzip", size) if path.end_with?(".js")
          [ path, asset ]
        end
        {
          "total" => assets.values.sum { |asset| asset.fetch("wire") },
          "budget" => { "kind" => "startup_gzip", "bytes" => STARTUP_GZIP_BUDGET_BYTES },
          "estimated" => !known,
          "assets" => assets,
          "lazy_chunks" => lazy_chunks
        }
      end

      private
        def wire_size(path, size, accept_encoding)
          available = variants.fetch(path, {})
          return ([ size ] + available.values).min if accept_encoding.nil?

          ENCODINGS.each_key do |encoding|
            next unless available.key?(encoding)
            return available.fetch(encoding) if PrecompressedAssetServer.accepts_encoding?(accept_encoding, encoding)
          end
          size
        end
    end

    # The shell renders on every navigation; the sizes only change with a new
    # build, so they are computed once per revision and manifest. Choosing the
    # encoding per request is a lookup.
    def self.current
      manifest_path = Rails.root.join(ViteEntrypoint::MANIFEST_PATH)
      # Checked first so a checkout without a build does not compile every
      # stylesheet on each render only to give up.
      raise ViteEntrypoint::Missing, "Vite manifest is missing: #{manifest_path}" unless manifest_path.file?

      key = [ SyrusVersion.current, manifest_path.mtime ]
      cached = @current
      return cached.last if cached && cached.first == key

      result = new(
        manifest_path: manifest_path,
        builds_root: Rails.root.join("app/assets/builds"),
        compressed_root: Rails.application.config.assets.output_path,
        stylesheets: app_stylesheets,
        prefix: Rails.application.config.assets.prefix
      ).result
      @current = [ key, result ]
      result
    end

    def self.reset!
      @current = nil
    end

    # The same set `stylesheet_link_tag(:app)` links, with the size of what is
    # served for each.
    def self.app_stylesheets
      assets = Rails.application.assets
      prefix = Rails.application.config.assets.prefix
      assets.load_path.asset_paths_by_glob("#{Rails.root.join('app/assets')}/**/*.css").filter_map do |logical_path|
        asset = assets.load_path.find(logical_path)
        next unless asset

        [ "#{prefix}/#{asset.digested_path}", asset.length ]
      end.to_h
    end

    # compressed_root is where the published assets and their .br/.gz variants
    # live (public/assets); a development checkout has none, and then every
    # file travels uncompressed.
    def initialize(manifest_path:, builds_root:, stylesheets: {}, compressed_root: nil, prefix: "/assets")
      @manifest_path = Pathname.new(manifest_path)
      @builds_root = Pathname.new(builds_root)
      @compressed_root = compressed_root && Pathname.new(compressed_root)
      @stylesheets = stylesheets
      @prefix = prefix
    end

    def result
      manifest = JSON.parse(manifest_path.read)
      sizes = {}
      ViteEntrypoint.new(manifest_path).startup_files.each do |file|
        path = builds_root.join(file)
        sizes["#{prefix}/#{file}"] = path.file? ? path.size : 0
      end
      stylesheets.each { |path, bytes| sizes[path] ||= bytes.to_i }
      lazy_chunks = manifest.filter_map do |source, chunk|
        next unless chunk["isDynamicEntry"] && chunk["file"]

        file = builds_root.join(chunk.fetch("file"))
        [ source, { "file" => chunk.fetch("file"), "size" => file.file? ? file.size : 0 } ]
      end.to_h
      Result.new(sizes: sizes, variants: sizes.keys.to_h { |path| [ path, variants_for(path) ] }, lazy_chunks: lazy_chunks)
    end

    private
      attr_reader :manifest_path, :builds_root, :compressed_root, :stylesheets, :prefix

      def variants_for(path)
        return {} unless compressed_root

        relative = path.delete_prefix("#{prefix}/")
        ENCODINGS.each_with_object({}) do |(encoding, extension), found|
          file = compressed_root.join("#{relative}#{extension}")
          found[encoding] = file.size if file.file?
        end
      end
  end
end
