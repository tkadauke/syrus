require "pathname"

module Syrus
  # Fails the production asset build when a published SPA module points at a
  # file the image will not serve under that exact name. Vite writes import
  # specifiers before Propshaft publishes the files, so any rename in between
  # -- an extra digest, a dropped file -- only shows up in the browser, where
  # the missing module falls through to the HTML app shell and fails with
  # "'text/html' is not a valid JavaScript MIME type" on whichever lazy route
  # touches it first.
  class SpaBuildVerifier
    class BrokenReferences < StandardError; end

    # `./spa-x.digested.js` relative to the importer, `/assets/...` absolute,
    # or a bare `spa-x.digested.js` from Vite's preload-dependency map, which
    # is relative to the `/assets/` base. Only JS and CSS: library bundles also
    # carry data paths (Excalidraw's `./fonts/...`) they resolve elsewhere.
    REFERENCE = %r{["'`](\./[^"'`\s]+?\.(?:js|mjs|css)|/assets/[^"'`\s]+?\.(?:js|mjs|css)|spa-[^"'`\s/]+?\.(?:js|mjs|css))["'`]}

    def initialize(output_path:)
      @output_path = Pathname.new(output_path)
    end

    def call
      broken = spa_modules.flat_map do |path|
        path.read.scan(REFERENCE).flatten.uniq.filter_map do |reference|
          target = resolve(path, reference)
          "#{path.relative_path_from(output_path)} -> #{reference}" unless target.file?
        end
      end
      return if broken.empty?

      raise BrokenReferences, "SPA modules reference files missing from #{output_path}:\n  #{broken.join("\n  ")}"
    end

    private
      attr_reader :output_path

      def spa_modules
        output_path.glob("spa-*.digested.js")
      end

      def resolve(importer, reference)
        if reference.start_with?("/assets/")
          output_path.join(reference.delete_prefix("/assets/"))
        elsif reference.start_with?("./")
          importer.dirname.join(reference)
        else
          output_path.join(reference)
        end
      end
  end
end
