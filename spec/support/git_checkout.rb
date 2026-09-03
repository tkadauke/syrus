# Some specs exercise tooling that reads the git working tree — the plugin
# source-boundary audit's untracked-file handling, and `bin/plugin-boundary-audit`
# itself, which builds its temporary copy with `git archive`.
#
# Those specs cannot run inside a copy that has no `.git`, which is exactly
# what `bin/plugin-boundary-audit` produces. Tagging them keeps the
# physical-removal audit's suite run meaningful instead of reporting failures
# that are artifacts of the harness.
RSpec.configure do |config|
  config.before(:each, :requires_git_checkout) do
    unless Rails.root.join(".git").exist?
      skip("requires a git checkout; this tree has no .git (see spec/support/git_checkout.rb)")
    end
  end
end

# Some specs need a *particular* bundled plugin as their fixture — core's
# plugin-purge lifecycle, for instance, can only be exercised against a plugin
# that really owns a table. Those examples are tagged with the plugin they
# need, so `bin/plugin-boundary-audit <that plugin>` skips them instead of
# reporting a failure that is really "the fixture was deleted on purpose".
RSpec.configure do |config|
  # Names are plugin *directory* names under plugins/, which are not always the
  # gem name (plugins/rails ships the `syrus_rails` gem).
  #
  # A typo'd name would otherwise skip silently forever, which is worse than no
  # guard at all. A normal checkout has every bundled plugin present, so a name
  # that is missing there is a typo and raises; only the `git archive` copy
  # bin/plugin-boundary-audit builds (no .git) is allowed to skip.
  config.before(:each, :requires_plugin) do |example|
    names = Array(example.metadata[:requires_plugin]).map(&:to_s)
    missing = names.reject { |name| Rails.root.join("plugins", name).directory? }
    next if missing.empty?

    if Rails.root.join(".git").exist?
      raise ArgumentError,
            "requires_plugin: #{missing.join(', ')} — no such directory under plugins/ " \
            "(use the directory name, e.g. \"rails\", not the gem name \"syrus_rails\")"
    end

    skip("requires the #{missing.join(', ')} plugin(s), not installed in this checkout")
  end
end
