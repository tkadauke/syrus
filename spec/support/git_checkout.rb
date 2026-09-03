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
