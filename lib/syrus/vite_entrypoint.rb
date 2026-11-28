require "json"
require "pathname"

module Syrus
  # The SPA entry is content-hashed (`spa-entry-<hash>.digested.js`) because
  # lazy chunks import shared code back from it by that exact name. The page
  # has to load the same URL, so the layout reads the current name from the
  # manifest Vite writes next to the build instead of a fixed alias.
  class ViteEntrypoint
    MANIFEST_PATH = "app/assets/builds/.vite/manifest.json".freeze
    ENTRY = "app/frontend/main.tsx".freeze

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

      manifest = JSON.parse(manifest_path.read)
      manifest.fetch("app/frontend/main.tsx").fetch("file")
    rescue KeyError
      raise Missing, "Vite manifest #{manifest_path} does not list app/frontend/main.tsx"
    end

    # The files a first render waits for: the entry and everything it imports
    # statically, transitively, plus the CSS Vite attached to those chunks.
    # Dynamic imports are lazy routes and do not block startup.
    def startup_files
      manifest = parsed_manifest
      seen = {}
      files = []
      queue = [ ENTRY ]
      until queue.empty?
        key = queue.shift
        next if seen[key]

        seen[key] = true
        chunk = manifest.fetch(key)
        files << chunk.fetch("file")
        files.concat(Array(chunk["css"]))
        queue.concat(Array(chunk["imports"]))
      end
      files.uniq
    rescue KeyError => error
      raise Missing, "Vite manifest #{manifest_path} is incomplete: #{error.message}"
    end

    def plugin_import_map
      manifest = JSON.parse(manifest_path.read)
      sources = {
        "react" => "app/frontend/pluginHost/react.ts",
        "react/jsx-runtime" => "app/frontend/pluginHost/reactJsxRuntime.ts",
        "react-dom" => "app/frontend/pluginHost/reactDom.ts",
        "react-dom/client" => "app/frontend/pluginHost/reactDomClient.ts",
        "@tanstack/react-query" => "app/frontend/pluginHost/reactQuery.ts",
        "i18next" => "app/frontend/pluginHost/i18next.ts",
        "react-i18next" => "app/frontend/pluginHost/reactI18next.ts",
        "@syrus/plugin-sdk" => "app/frontend/pluginHost/sdk.ts"
      }
      { "imports" => sources.transform_values { |source| "/assets/#{manifest.fetch(source).fetch('file')}" } }
    rescue Errno::ENOENT, JSON::ParserError, KeyError => error
      raise Missing, "Vite plugin host entries are missing: #{error.message} (run `npm run build`)"
    end

    private
      attr_reader :manifest_path

      def parsed_manifest
        raise Missing, "Vite manifest is missing: #{manifest_path} (run `npm run build`)" unless manifest_path.file?

        JSON.parse(manifest_path.read)
      rescue JSON::ParserError => error
        raise Missing, "Vite manifest #{manifest_path} is unreadable: #{error.message}"
      end
  end
end
