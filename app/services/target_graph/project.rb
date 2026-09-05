class TargetGraph
  # An operator-facing workflow boundary (preview, hooks, visual review,
  # adversarial review criteria, coverage policy) as distinct from the
  # lower-level Target execution nodes it groups. See DOC-20 "Projects".
  Project = Data.define(:id, :label, :kind, :path, :owner_config_path) do
    ID_PATTERN = /\A[A-Za-z0-9_-]+\z/

    def initialize(id:, label: nil, kind: nil, path: "", owner_config_path: nil)
      id = id.to_s.strip
      raise ArgumentError, "project id must not be blank" if id.empty?
      raise ArgumentError, "project id #{id.inspect} must match #{ID_PATTERN.inspect}" unless id.match?(ID_PATTERN)

      path = path.to_s.strip
      if path.start_with?("/") || path.end_with?("/")
        raise ArgumentError, "project path #{path.inspect} must not start or end with /"
      end

      super(
        id: id,
        label: label.to_s.strip.presence || id,
        kind: kind&.to_s&.strip&.presence,
        path: path,
        owner_config_path: owner_config_path&.to_s
      )
    end

    # A project scoped to the repository root (the implicit `//:repo`
    # project, or an explicit `project:` block declared in the root
    # `.syrus.yml`).
    def root?
      path.empty?
    end
  end
end
