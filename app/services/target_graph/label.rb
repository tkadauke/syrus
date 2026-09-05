# Canonical Buck-style label for a target-graph node, e.g. `//:repo`,
# `//cli:default`, `//cli:grade/tests`, `//desktop:build/package`.
#
# `project_path` is the slash-joined directory path of the owning project,
# empty for the repository root. `target_name` is the slash-joined target
# name within that project (a plain name like `default`, or a
# namespaced generated name like `grade/tests`). Both are validated and
# normalized so two labels built from equivalent input always compare
# equal and render the same canonical string — see DOC-20 "Labels".
class TargetGraph
  class Label
    ParseError = Class.new(StandardError)

    FULL_PATTERN = %r{\A//(?<project_path>[^:]*):(?<target_name>[^:]+)\z}
    SEGMENT_PATTERN = /\A[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?\z/

    ROOT_PROJECT_PATH = "".freeze
    ROOT_TARGET_NAME = "repo".freeze
    DEFAULT_TARGET_NAME = "default".freeze

    attr_reader :project_path, :target_name

    # Parses a full canonical label string such as "//cli:grade/tests".
    def self.parse(value)
      str = value.to_s.strip
      match = FULL_PATTERN.match(str)
      raise ParseError, "invalid target label #{str.inspect}: expected //<project_path>:<target_name>" unless match

      new(project_path: match[:project_path], target_name: match[:target_name])
    end

    # Accepts either an already-parsed Label (returned as-is) or a raw
    # string to parse. Convenience for call sites that may receive either.
    def self.coerce(value)
      value.is_a?(Label) ? value : parse(value)
    end

    # The implicit label every repository has: `//:repo`.
    def self.root
      new(project_path: ROOT_PROJECT_PATH, target_name: ROOT_TARGET_NAME)
    end

    # The implicit default-target label for a (possibly nested) project,
    # e.g. default_for("cli") -> `//cli:default`.
    def self.default_for(project_path)
      new(project_path: project_path, target_name: DEFAULT_TARGET_NAME)
    end

    def initialize(project_path:, target_name:)
      @project_segments = normalize_segments(project_path, part: "project_path", allow_blank: true)
      @target_segments = normalize_segments(target_name, part: "target_name", allow_blank: false)
      freeze
    end

    def project_path
      @project_segments.join("/")
    end

    def target_name
      @target_segments.join("/")
    end

    def project_segments
      @project_segments.dup
    end

    def target_segments
      @target_segments.dup
    end

    def root_project?
      @project_segments.empty?
    end

    # The label of the implicit default target belonging to this label's
    # project — the anchor other targets in the same project depend on.
    def project_default_label
      root_project? ? self.class.root : self.class.default_for(project_path)
    end

    def to_s
      "//#{project_path}:#{target_name}"
    end
    alias_method :canonical, :to_s

    def ==(other)
      other.is_a?(Label) && project_path == other.project_path && target_name == other.target_name
    end
    alias_method :eql?, :==

    def hash
      [ self.class, project_path, target_name ].hash
    end

    def inspect
      "#<TargetGraph::Label #{self}>"
    end

    private

    def normalize_segments(raw, part:, allow_blank:)
      str = raw.to_s.strip
      return [] if str.empty? && allow_blank
      raise ParseError, "#{part} must not be blank" if str.empty?

      segments = str.split("/", -1)
      segments.each do |segment|
        unless SEGMENT_PATTERN.match?(segment)
          raise ParseError, "invalid #{part} segment #{segment.inspect} in #{str.inspect}"
        end
      end
      segments
    end
  end
end
