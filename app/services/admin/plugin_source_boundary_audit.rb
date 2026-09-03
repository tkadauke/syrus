require "open3"

module Admin
  class PluginSourceBoundaryAudit
    Manifest = Data.define(:name, :dir_name, :path, :depends_on, :constants, :gem_name)
    Violation = Data.define(:source, :target, :path, :line, :evidence, :reason) do
      def message
        "#{path}:#{line}: #{source} references #{target} (#{reason}): #{evidence.strip}"
      end
    end

    CORE_ROOTS = %w[app lib config bin].freeze
    SOURCE_EXTENSIONS = %w[.rb .rake .erb .ts .tsx .js .jsx].freeze
    COMMENT_ONLY = /\A\s*(#|\/\/)/

    # Narrow exceptions where core is intentionally probing an optional plugin
    # behind a constant-defined guard. These keep optionality because the files
    # still parse and boot when the plugin gem is physically absent.
    GUARDED_CORE_CONSTANTS = {
      "app/services/agent_environment_snapshot.rb" => %w[DesignDocs],
      "app/services/prompts/chat_system.rb" => %w[DesignDocs],
      "app/services/mcp/sidecar.rb" => %w[SyrusBrowser]
    }.freeze

    # Framework-level extension boundaries that must mention plugin paths or
    # component keys in order to discover installed plugin assets.
    CORE_PATH_EXCEPTIONS = [
      %r{\Aapp/frontend/plugin(AdminPages|SidebarPages|WorkspaceTabs)\.tsx\z},
      %r{\Aapp/frontend/pluginArtifactRenderers\.tsx\z},
      %r{\Aapp/frontend/routes/App\.tsx\z},
      %r{\Aapp/frontend/routes/chat/WorkspacePanels\.tsx\z},
      %r{\Aapp/frontend/routes/chat/workspaceTabs\.ts\z},
      %r{\Aapp/services/admin/plugin_source_boundary_audit\.rb\z},
      %r{\Aapp/services/skills/},
      %r{\Aconfig/application\.rb\z},
      %r{\Alib/generators/syrus/plugin/},
      %r{\Abin/plugin-boundary-audit\z}
    ].freeze

    # Existing bundled-provider setup flows still import plugin frontend modules
    # directly. They are kept explicit so the prototype does not hide the
    # remaining source-tree optionality work; the physical-removal script is the
    # stronger check that will continue to expose these if the plugin is removed.
    LEGACY_FRONTEND_IMPORT_EXCEPTIONS = [
      %r{\Aapp/frontend/components/ConfigureAgentModal\.tsx\z},
      %r{\Aapp/frontend/components/credentials/CredentialCard\.tsx\z}
    ].freeze

    def self.bundled_manifests(root: Rails.root)
      new(root: root).bundled_manifests
    end

    def initialize(root: Rails.root, manifests: nil)
      @root = Pathname.new(root)
      @manifests = manifests
    end

    def bundled_manifests
      @bundled_manifests ||= plugin_dirs.filter_map { |dir| manifest_for(dir) }.sort_by(&:name)
    end

    def bundled_manifest_names
      bundled_manifests.map(&:name)
    end

    def bundled_gem_paths
      bundled_manifests.to_h { |manifest| [ manifest.name, manifest.path ] }
    end

    def missing_dependencies
      names = bundled_manifest_names.to_set
      bundled_manifests.flat_map do |manifest|
        manifest.depends_on.reject { |dependency| names.include?(dependency) }.map do |dependency|
          [ manifest.name, dependency ]
        end
      end
    end

    def graph
      @graph ||= Admin::PluginDependencyGraph.new(graph_manifests)
    end

    def core_violations
      manifests = bundled_manifests
      scan_files(core_source_files, manifests).flat_map do |path, line_number, line|
        manifests.filter_map do |manifest|
          next if allowed_core_reference?(path, manifest, line)

          reason = reference_reason(line, manifest)
          next unless reason

          Violation.new(
            source: "core",
            target: manifest.name,
            path: relative(path),
            line: line_number,
            evidence: line,
            reason: reason
          )
        end
      end
    end

    def plugin_violations
      manifests = bundled_manifests

      manifests.flat_map do |source_manifest|
        allowed_targets = graph.dependencies_for(source_manifest.name).to_set
        scan_files(plugin_source_files_under(source_manifest.path), manifests).flat_map do |path, line_number, line|
          manifests.filter_map do |target_manifest|
            next if target_manifest.name == source_manifest.name
            next if allowed_targets.include?(target_manifest.name)

            reason = reference_reason(line, target_manifest)
            next unless reason

            Violation.new(
              source: source_manifest.name,
              target: target_manifest.name,
              path: relative(path),
              line: line_number,
              evidence: line,
              reason: reason
            )
          end
        end
      end
    end

    def removed_plugin_names_for(plugin_name)
      name = plugin_name.to_s
      return [] unless bundled_manifest_names.include?(name)

      [ name, *graph.dependents_for(name) ].uniq
    end

    private

    attr_reader :root

    def graph_manifests
      return @manifests if @manifests

      bundled_manifests.map do |manifest|
        Syrus::Plugin::Manifest.new(
          name: manifest.name,
          version: "0.0.0",
          provides: {},
          metadata: {},
          depends_on: manifest.depends_on
        )
      end
    end

    def plugin_dirs
      root.join("plugins").children.select(&:directory?)
    end

    def manifest_for(dir)
      manifest_files = Dir.glob(dir.join("lib/**/*.rb").to_s).sort
      source_files = Dir.glob(dir.join("{app,lib}/**/*.rb").to_s).sort
      source = manifest_files.map { |file| File.read(file) }.join("\n")
      name = source[/Syrus::PluginRegistry\.register\(\s*name:\s*["']([^"']+)["']/m, 1]
      return unless name

      Manifest.new(
        name: name,
        dir_name: dir.basename.to_s,
        path: relative(dir),
        depends_on: source.scan(/depends_on:\s*\[(.*?)\]/m).flat_map { |match| match.first.scan(/["']([^"']+)["']/).flatten }.uniq,
        constants: owned_constants(dir, source_files),
        gem_name: gem_name_for(dir)
      )
    end

    def gem_name_for(dir)
      gemspec = Dir.glob(dir.join("*.gemspec").to_s).first
      return dir.basename.to_s unless gemspec

      File.basename(gemspec, ".gemspec")
    end

    def owned_constants(dir, files)
      (path_derived_constants(dir, files) + explicit_constants(files)).uniq
    end

    def path_derived_constants(dir, files)
      files.filter_map do |file|
        relative_file = Pathname.new(file).relative_path_from(dir).to_s
        next if relative_file.match?(%r{\Alib/[^/]+\.rb\z})

        relative_file = relative_file.sub(%r{\A(app/(controllers|jobs|models|policies|services)/|lib/)}, "")
        next unless relative_file.end_with?(".rb")

        relative_file.delete_suffix(".rb").camelize
      end
    end

    def explicit_constants(files)
      files.flat_map do |file|
        relative_file = relative(file)
        File.readlines(file).filter_map do |line|
          constant = line[/\A\s*(?:module|class)\s+([A-Z][A-Za-z0-9_:]*)\b/, 1]
          next unless constant
          next unless constant.include?("::") || relative_file.match?(%r{\Aplugins/[^/]+/lib/[^/]+\.rb\z})
          next if shared_extension_namespace?(constant)

          constant
        end
      end
    end

    def shared_extension_namespace?(constant)
      %w[
        AgentProviders
        Api
        ChatProviders
        Filters
        InputSources
        Job
        SourceControl
      ].include?(constant)
    end

    def core_source_files
      CORE_ROOTS.flat_map do |dir|
        source_files_under(dir)
      end.reject { |path| path.to_s.include?("/spec/") || path.basename.to_s.end_with?(".test.ts", ".test.tsx") }
    end

    def plugin_source_files_under(path)
      source_files_under(path).reject do |candidate|
        rel = relative(candidate)
        rel.include?("/spec/") || candidate.basename.to_s.end_with?(".test.ts", ".test.tsx")
      end
    end

    def source_files_under(path)
      absolute = root.join(path)
      return [] unless absolute.exist?

      if absolute.file?
        [ absolute ]
      else
        Dir.glob(absolute.join("**/*").to_s)
           .map { |candidate| Pathname.new(candidate) }
           .select { |candidate| candidate.file? && SOURCE_EXTENSIONS.include?(candidate.extname) }
           .select { |candidate| tracked?(candidate) }
      end
    end

    # The audit is a check on committed source, so untracked files are out of
    # scope. Without this, any developer who has run a frontend build gets a
    # false positive from the minified bundle in app/assets/builds (gitignored,
    # and full of substrings that look like short plugin names).
    #
    # bin/plugin-boundary-audit runs against a `git archive HEAD` copy that has
    # no .git directory, so an unavailable index means "scan everything" rather
    # than "scan nothing".
    def tracked?(candidate)
      return true if tracked_paths.nil?

      tracked_paths.include?(relative(candidate))
    end

    def tracked_paths
      return @tracked_paths if defined?(@tracked_paths)

      @tracked_paths = begin
        out, status = Open3.capture2("git", "-C", root.to_s, "ls-files", "-z")
        status.success? ? out.split("\0").to_set : nil
      rescue StandardError
        nil
      end
    end

    def scan_files(paths, manifests)
      reference_pattern = reference_pattern_for(manifests)

      paths.flat_map do |path|
        File.readlines(path).each_with_index.filter_map do |line, index|
          next if line.match?(COMMENT_ONLY)
          next unless line.match?(reference_pattern)

          [ path, index + 1, line ]
        end
      end
    end

    def reference_pattern_for(manifests)
      tokens = manifests.flat_map do |manifest|
        [ "plugins/#{manifest.dir_name}/", "#{manifest.dir_name}/", manifest.gem_name, *manifest.constants ]
      end.compact.uniq.reject(&:blank?)

      Regexp.union(tokens)
    end

    def reference_reason(line, manifest)
      return "plugin source path" if line.include?("plugins/#{manifest.dir_name}/")
      return "plugin frontend module key" if frontend_module_key_reference?(line, manifest)
      return "plugin gem name" if manifest.gem_name.present? && line.match?(/gem\s+["']#{Regexp.escape(manifest.gem_name)}["']/)

      unquoted_line = line.gsub(/"[^"]*"|'[^']*'/, "")
      constant = manifest.constants.find { |name| unquoted_line.match?(/\b#{Regexp.escape(name)}\b/) }
      return "plugin-owned constant #{constant}" if constant

      nil
    end

    def frontend_module_key_reference?(line, manifest)
      return false unless line.match?(/component|route|workspace|sidebar/i)

      line.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(manifest.dir_name)}\//)
    end

    def allowed_core_reference?(path, manifest, line)
      rel = relative(path)
      return true if CORE_PATH_EXCEPTIONS.any? { |pattern| rel.match?(pattern) }
      return true if LEGACY_FRONTEND_IMPORT_EXCEPTIONS.any? { |pattern| rel.match?(pattern) } && line.include?("@plugins/")

      guarded = GUARDED_CORE_CONSTANTS.fetch(rel, [])
      guarded.any? do |constant|
        manifest.constants.include?(constant) &&
          line.match?(/\b#{Regexp.escape(constant)}\b/) &&
          File.read(path).match?(/defined\?\(#{Regexp.escape(constant)}(?:::|\))/)
      end
    end

    def relative(path)
      Pathname.new(path).relative_path_from(root).to_s
    end
  end
end
