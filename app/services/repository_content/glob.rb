module RepositoryContent
  # The one glob dialect every caller and provider shares, so a pattern means
  # the same thing whichever provider answered:
  #
  #   *        anything within one path segment (including dotfiles)
  #   **/      zero or more directories
  #   dir/**   everything below dir
  #   ?        one character within a segment
  #   {a,b}    either alternative
  #   [abc]    a character class
  #
  # Paths are matched relative to the repository root, `/`-separated.
  module Glob
    FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

    module_function

    def match?(patterns, path)
      Array(patterns).any? { |pattern| File.fnmatch?(normalize(pattern), path, FLAGS) }
    end

    def filter(patterns, entries)
      return entries if patterns.blank?

      entries.select { |entry| match?(patterns, entry.respond_to?(:path) ? entry.path : entry) }
    end

    # File.fnmatch treats a trailing `**` as a single `*`; the dialect says it
    # means everything below.
    def normalize(pattern)
      pattern = pattern.to_s.delete_prefix("/")
      return "**/*" if pattern == "**"

      pattern.end_with?("/**") ? "#{pattern}/*" : pattern
    end
  end
end
