require "json"
require "pathname"

module Syrus
  # The SPA entry is content-hashed (`spa-entry-<hash>.digested.js`) because
  # lazy chunks import shared code back from it by that exact name. The page
  # has to load the same URL, so the layout reads the current name from the
  # manifest Vite writes next to the build instead of a fixed alias.
  class ViteEntrypoint
    MANIFEST_PATH = "app/assets/builds/.vite/manifest.json".freeze

    class Missing < StandardError; end

    # Every shell render asks; re-read only when a build rewrote the manifest.
    def self.current
      path = Rails.root.join(MANIFEST_PATH)
      mtime = path.file? ? path.mtime : nil
      cached = @current
      return cached.last if cached && mtime && cached.first == mtime

      file = new(path).file
      @current = [ mtime, file ]
      file
    end

    def initialize(manifest_path)
      @manifest_path = Pathname.new(manifest_path)
    end

    def file
      raise Missing, "Vite manifest is missing: #{manifest_path} (run `npm run build`)" unless manifest_path.file?

      entries = JSON.parse(manifest_path.read).values.select { |chunk| chunk["isEntry"] }
      raise Missing, "Vite manifest #{manifest_path} lists #{entries.size} entries, expected 1" unless entries.one?

      entries.first.fetch("file")
    end

    private
      attr_reader :manifest_path
  end
end
