module PushProtection
  # Validates the agent's result by repository topology, never by command
  # history. Returns a list of precise, agent-readable violations (empty when
  # the contract was honoured).
  class TopologyValidator
    def initialize(repo:, branch:, anchor:, rejected_shas:, baseline:, allowed_paths:)
      @repo = repo
      @branch = branch
      @anchor = anchor
      @rejected_shas = rejected_shas
      @baseline = baseline
      @allowed_paths = allowed_paths.map { |p| p.to_s.sub(/:\d+\z/, "") }
    end

    def violations
      v = []
      v.concat(history_violations)
      v.concat(repository_state_violations)
      v.concat(content_violations) if v.empty?
      v
    end

    private

    attr_reader :repo, :branch, :anchor, :rejected_shas, :baseline, :allowed_paths

    def history_violations
      v = []
      head = repo.head
      parents = repo.parents(head)
      unless parents == [ anchor ]
        v << "HEAD must have exactly one parent, the clean anchor #{anchor}; found #{parents.size} parent(s): #{parents.join(', ').presence || 'none'}. " \
             "Leave one commit directly atop #{anchor} (amending the tip is allowed)."
      end
      leaked = rejected_shas.select { |sha| repo.commit_exists?(sha) && repo.ancestor?(sha, head) }
      v << "Rejected commit(s) #{leaked.map { |s| s.first(12) }.join(', ')} are still reachable from HEAD; they must not be ancestors." if leaked.any?
      v
    end

    def repository_state_violations
      v = []
      refs = repo.refs_except(branch)
      v << "Repository refs changed (#{(refs - baseline['refs']).size} added/moved, #{(baseline['refs'] - refs).size} removed); do not create, move or delete refs." if refs != baseline["refs"]
      v << "Git remotes changed; do not add, remove or edit remotes." if repo.remotes != baseline["remotes"]
      v << "Repository configuration (.git/config) changed; do not modify it." if repo.config_text != baseline["config"]
      if repo.metadata_digest != baseline["git_metadata"]
        changed = (repo.metadata_digest.to_a - baseline["git_metadata"].to_a).map(&:first) | (baseline["git_metadata"].keys - repo.metadata_digest.keys)
        v << "Git metadata changed (#{changed.first(10).join(', ')}); do not create or edit hooks, .git/info or worktree config."
      end
      v << "Working tree is not clean; commit or discard leftovers." if repo.dirty?
      v
    end

    def content_violations
      v = []
      head = repo.head
      v << "Submodules (gitlinks) changed; do not add, remove or move submodules." if repo.gitlinks(head) != baseline["gitlinks"]
      v << ".gitmodules changed; do not modify it." if repo.gitmodules(head) != baseline["gitmodules"]
      unrelated = repo.changed_paths(baseline["candidate_tree"], repo.tree(head)) - allowed_paths
      v << "Unrelated files changed: #{unrelated.first(20).join(', ')}. Only these paths may change: #{allowed_paths.join(', ').presence || '(none)'}." if unrelated.any?
      v
    end
  end
end
