require "json"
require "pathname"

module Syrus
  # How much the SPA shell has to download before React can render, so the
  # startup screen can show real progress on a slow connection instead of an
  # open-ended spinner.
  #
  # The set is the Vite entry plus its static imports (ViteEntrypoint#
  # startup_files) and every stylesheet the shell links. Sizes are the
  # uncompressed bytes on disk: the service worker counts decoded bytes as they
  # stream, and resource timing reports finished assets, so both measure
  # against the same unit.
  class StartupAssets
    # Paths as the page requests them ("/assets/<file>") mapped to their size.
    Result = Data.define(:assets) do
      def total_bytes
        assets.values.sum
      end

      def as_json(*)
        { "total" => total_bytes, "assets" => assets }
      end
    end

    # The shell renders on every navigation; the answer only changes with a
    # new build, so it is computed once per revision and manifest.
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
        stylesheets: app_stylesheets
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

    def initialize(manifest_path:, builds_root:, stylesheets: {}, prefix: "/assets")
      @manifest_path = Pathname.new(manifest_path)
      @builds_root = Pathname.new(builds_root)
      @stylesheets = stylesheets
      @prefix = prefix
    end

    def result
      assets = {}
      ViteEntrypoint.new(manifest_path).startup_files.each do |file|
        path = builds_root.join(file)
        assets["#{prefix}/#{file}"] = path.file? ? path.size : 0
      end
      stylesheets.each { |path, bytes| assets[path] ||= bytes.to_i }
      Result.new(assets: assets)
    end

    private
      attr_reader :manifest_path, :builds_root, :stylesheets, :prefix
  end
end
