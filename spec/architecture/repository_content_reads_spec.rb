require "rails_helper"

# Everything that reads a repository without cloning it goes through
# RepositoryContent, so a mirror (or another host) can answer first. A new
# call straight to GithubClient's content readers would quietly bypass the
# mirror, cost a GitHub request per read, and tie that code to GitHub. The
# readers exist only for github_host, the provider built on them.
RSpec.describe "repository content reads" do
  READERS = %w[file_bytes_at commit_tree_entries compare_file_changes commit_sha_for commit_tree_sha].freeze
  ALLOWED = %r{\A(plugins/github_host/|app/services/github_client\.rb\z)}

  it "go through RepositoryContent, not GithubClient's content readers" do
    pattern = /\.(#{READERS.join('|')})\(/
    offenders = Dir.glob(Rails.root.join("{app,lib,plugins/*/app,plugins/*/lib}/**/*.rb")).filter_map do |file|
      relative = Pathname(file).relative_path_from(Rails.root).to_s
      next if relative.match?(ALLOWED)

      File.readlines(file).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.match?(pattern)
      end.presence
    end.flatten

    expect(offenders).to be_empty, <<~MSG
      Read repository content through RepositoryContent (see plugins.md,
      repository_content_provider) instead of calling GithubClient directly:
        #{offenders.join("\n  ")}
    MSG
  end

  # Guard the guard: the readers it names must still exist, or it checks
  # nothing.
  it "names readers GithubClient still has" do
    expect(READERS.map { |name| GithubClient.method_defined?(name) }).to all(be(true))
  end
end
