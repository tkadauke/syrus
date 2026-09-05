class TargetGraph
  # Canonical Buck-style label: `//<package>:<name>`, e.g. `//:repo`,
  # `//cli:default`, `//cli:grade/tests`, `//desktop:build/package`.
  #
  # `package` is the directory a `.syrus.yml` lives in relative to the
  # repository root ("" for the root file). `name` identifies the target (or
  # project) within that package and may itself contain `/` segments
  # (`grade/tests`, `build/package`) for generated-legacy-node namespacing.
  class Label < Data.define(:package, :name)
    ParseError = Class.new(TargetGraph::Error)

    SEGMENT_PATTERN = /\A[A-Za-z0-9_-]+\z/
    ABSOLUTE_PATTERN = %r{\A//(?<package>[^:]*):(?<name>.+)\z}

    class << self
      # Parses an already-absolute label string (`//cli:grade/tests`).
      def parse(raw)
        raw = raw.to_s
        match = ABSOLUTE_PATTERN.match(raw)
        raise ParseError, "#{raw.inspect} is not a canonical label (expected //package:name)" unless match

        new(package: match[:package], name: match[:name])
      end

      # Resolves a label reference declared inside the `.syrus.yml` that
      # owns `package` (e.g. "cli", or "" for the repo root). Absolute
      # references (`//...`) resolve as written; `:name` references resolve
      # relative to `package`, mirroring the same-package dependency
      # shorthand from DOC-20 (`deps: [":renderer"]` inside `/desktop/.syrus.yml`
      # resolves to `//desktop:renderer`).
      def resolve(raw, package:)
        raw = raw.to_s
        return parse(raw) if raw.start_with?("//")
        return new(package: package, name: raw.delete_prefix(":")) if raw.start_with?(":")

        raise ParseError, "#{raw.inspect} must start with // (absolute) or : (relative to #{package.inspect})"
      end

      def root(name)
        new(package: "", name: name)
      end
    end

    def initialize(package:, name:)
      super(
        package: normalize_segments(package, field: "package", allow_blank: true),
        name: normalize_segments(name, field: "name", allow_blank: false)
      )
    end

    def to_s
      "//#{package}:#{name}"
    end

    def root?
      package.empty?
    end

    def package_segments
      package.split("/")
    end

    def name_segments
      name.split("/")
    end

    def ==(other)
      other.is_a?(Label) && to_s == other.to_s
    end
    alias eql? ==

    def hash
      to_s.hash
    end

    private

    def normalize_segments(value, field:, allow_blank:)
      value = value.to_s.strip
      return "" if value.empty? && allow_blank
      raise ParseError, "label #{field} must not be blank" if value.empty?
      if value.start_with?("/") || value.end_with?("/") || value.include?("//")
        raise ParseError, "label #{field} #{value.inspect} must not start/end with / or contain //"
      end

      segments = value.split("/")
      invalid = segments.reject { |segment| segment.match?(SEGMENT_PATTERN) }
      raise ParseError, "label #{field} #{value.inspect} has invalid segment(s): #{invalid.join(', ')}" if invalid.any?

      segments.join("/")
    end
  end
end
