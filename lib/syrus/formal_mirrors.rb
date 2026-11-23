require "digest"
require "pathname"
require "prism"
require "yaml"

module Syrus
  # Drift detection for the Lean models (formal/INTEGRATION.md, layer 2). Each
  # model under formal/SyrusModel is a hand-written mirror of specific Ruby
  # methods. formal/mirrors.yml records, per model, those methods and a hash
  # of each method's source. When a mirrored method changes, the recorded hash
  # no longer matches and spec/architecture/formal_mirrors_spec.rb fails, so
  # the model is reviewed in the same change. After reviewing it,
  # `bin/formal-mirrors --update` records the new hashes.
  #
  # A method is named by its file, the innermost class or module that defines
  # it, and its name: "Steps::PrOpen#ensure_stack_base_fresh!" is written as
  # owner "PrOpen", method "ensure_stack_base_fresh!". Singleton methods
  # (`def self.x`) are written with a leading "self.".
  module FormalMirrors
    MANIFEST = "formal/mirrors.yml".freeze

    Mirror = Data.define(:model, :path, :owner, :method, :sha) do
      def label = "#{owner}#{method.start_with?('self.') ? '.' : '#'}#{method.delete_prefix('self.')} (#{path})"
    end

    module_function

    def manifest_path(root) = Pathname.new(root).join(MANIFEST)

    def mirrors(root)
      data = YAML.safe_load_file(manifest_path(root))
      Array(data.fetch("models")).flat_map do |entry|
        Array(entry.fetch("mirrors")).map do |mirror|
          Mirror.new(model: entry.fetch("model"), path: mirror.fetch("path"), owner: mirror.fetch("owner"),
            method: mirror.fetch("method"), sha: mirror["sha"])
        end
      end
    end

    # The hash of the method's source, or nil when the method is not found.
    def current_sha(root, mirror)
      source = method_source(Pathname.new(root).join(mirror.path), mirror.owner, mirror.method)
      source && Digest::SHA256.hexdigest(source)[0, 16]
    end

    def method_source(file, owner, method)
      return nil unless file.file?

      singleton = method.start_with?("self.")
      name = method.delete_prefix("self.").to_sym
      found = find_def(Prism.parse(file.read).value, owner, name, singleton, nil)
      found&.slice
    end

    def find_def(node, owner, name, singleton, enclosing)
      return nil unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::DefNode) && node.name == name && (node.receiver.is_a?(Prism::SelfNode)) == singleton && enclosing == owner
        return node
      end

      enclosing = constant_name(node.constant_path) if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      node.compact_child_nodes.each do |child|
        found = find_def(child, owner, name, singleton, enclosing)
        return found if found
      end
      nil
    end

    # The last segment of `Foo::Bar` or `Bar`.
    def constant_name(path) = path.slice.split("::").last

    # Rewrites the manifest with current hashes. Returns the mirrors whose hash
    # changed.
    def update!(root)
      path = manifest_path(root)
      data = YAML.safe_load_file(path)
      changed = []
      data.fetch("models").each do |entry|
        entry.fetch("mirrors").each do |mirror|
          record = Mirror.new(model: entry.fetch("model"), path: mirror.fetch("path"), owner: mirror.fetch("owner"),
            method: mirror.fetch("method"), sha: mirror["sha"])
          sha = current_sha(root, record) || raise(ArgumentError, "#{record.label} not found")
          changed << record unless sha == mirror["sha"]
          mirror["sha"] = sha
        end
      end
      path.write(header + data.to_yaml.delete_prefix("---\n"))
      changed
    end

    def header
      <<~YAML
        # Which Ruby methods each Lean model mirrors, with a hash of each method's
        # source (Syrus::FormalMirrors). spec/architecture/formal_mirrors_spec.rb
        # fails when a mirrored method changes: review the model, then run
        # `bin/formal-mirrors --update`.
      YAML
    end
  end
end
