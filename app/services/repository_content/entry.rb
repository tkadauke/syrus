module RepositoryContent
  # One path in a revision's tree.
  #
  #   type        "file", "symlink", "submodule", or "external" (svn externals,
  #               hg subrepos -- content that lives in another repository)
  #   size        bytes, nil when the provider does not know
  #   content_id  a content address when the VCS has one (git blob SHA), so
  #               callers can key caches on exactly the bytes they depend on;
  #               nil otherwise
  ENTRY_TYPES = %w[file symlink submodule external].freeze

  Entry = Data.define(:path, :type, :size, :content_id) do
    def initialize(path:, type: "file", size: nil, content_id: nil)
      raise ArgumentError, "unknown entry type #{type.inspect}" unless ENTRY_TYPES.include?(type)

      super
    end

    def file? = type == "file"
  end
end
