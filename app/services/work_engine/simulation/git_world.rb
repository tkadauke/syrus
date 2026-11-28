# frozen_string_literal: true

require "digest/sha1"
require "set"

module WorkEngine
  module Simulation
    # A small, deterministic model of the two things Syrus reads from outside
    # the database to decide how to move a branch: git topology and GitHub's
    # view of each pull request.
    #
    # Git is a commit DAG. A commit is an abstract id with parent pointers, a
    # *patch* id (what the change is) and the *paths* it touches (where it
    # lands). That is just enough for the questions production code asks:
    #
    #   * ancestry   -- `merge-base --is-ancestor`, `rev-list a..b`
    #   * rebase     -- replaying a commit onto a base that already holds a
    #                   commit with the same patch drops it (patch-equivalent,
    #                   as `git rebase` does); replaying it onto a base whose
    #                   new commits touch one of its paths with a different
    #                   patch conflicts (the add/add of a rewritten parent)
    #   * rewrites   -- a force-pushed branch is a new chain of commits; with
    #                   patch equivalence they keep their patch ids, without it
    #                   they get new ones on the same paths
    #   * merges     -- a PR merged with the default `rebase` method replays
    #                   its commits onto the base (patch-equivalent copies),
    #                   and GitHub's delete-branch-on-merge removes the head
    #                   ref and retargets PRs that were based on it
    #
    # Each PR's `mergeable_state` is derived from that topology the way GitHub
    # derives it: `clean` when the head contains the base tip and checks pass,
    # `blocked` when they do not, `behind` when the base moved without touching
    # the PR's paths, `dirty` when it did, and `unknown` while GitHub is still
    # computing (a scenario can ask for a number of unknown reads).
    #
    # Ids are SHA-1 hex strings derived from the scenario seed, so the whole
    # world is deterministic: replaying the same commit onto the same parent
    # twice yields the same id, the way a no-op rebase leaves a head unchanged.
    class GitWorld
      Commit = Data.define(:id, :parents, :patch, :paths, :label) do
        def merge? = parents.size > 1
      end

      PullRequest = Struct.new(
        :number, :job_key, :head_branch, :base_branch, :state, :merged, :merge_commit_sha,
        :synced_base_sha, :head_sha_at_close, :checks, :unknown_reads, :blocked, :body,
        keyword_init: true
      ) do
        def open? = state == "open"
      end

      # A local clone's state: where HEAD is and whether a rebase or
      # cherry-pick stopped on a conflict.
      Checkout = Struct.new(:key, :branch, :head, :operation, keyword_init: true)
      Operation = Data.define(:kind, :orig_head, :conflicts)

      ReplayResult = Data.define(:tip, :applied, :dropped, :conflict, :conflicts) do
        def conflicted? = conflict.present?
      end

      class Error < StandardError; end
      class UnknownRef < Error; end
      class MergeConflict < Error; end

      MERGE_METHODS = %w[rebase merge squash].freeze

      attr_reader :seed, :branches, :pull_requests, :default_branch, :merge_method
      attr_accessor :delete_branch_on_merge

      def initialize(seed:, default_branch: "main", delete_branch_on_merge: true, merge_method: "rebase")
        raise ArgumentError, "unknown merge method #{merge_method.inspect}" unless MERGE_METHODS.include?(merge_method.to_s)

        @seed = seed.to_s
        @default_branch = default_branch.to_s
        @delete_branch_on_merge = delete_branch_on_merge
        @merge_method = merge_method.to_s
        @commits = {}
        @labels = {}
        @branches = {}
        @pull_requests = {}
        @checkouts = {}
        @ancestors = {}
        @generation = {}
        @sequence = 0
      end

      # ---- commits ---------------------------------------------------------

      def commit!(label: nil, parents: [], patch: nil, paths: nil)
        parent_ids = Array(parents).map { |parent| resolve!(parent) }
        label = label&.to_s
        patch = (patch.presence || label.presence || "patch-#{next_sequence}").to_s
        paths = Array(paths.presence || [ "#{patch}.txt" ]).map(&:to_s).sort
        id = label ? sha_for(label) : derive_sha("commit", parent_ids.join(","), patch, paths.join(","), next_sequence)
        store!(Commit.new(id: id, parents: parent_ids, patch: patch, paths: paths, label: label))
      end

      def sha_for(label)
        Digest::SHA1.hexdigest("#{seed}:commit:#{label}")
      end

      def commit(sha) = @commits[sha.to_s]

      def commit?(ref) = resolve(ref).present?

      def label_sha(label) = @labels[label.to_s]

      def labels = @labels.dup

      # Resolves a commit label, a full id, a branch (also as origin/<name>,
      # refs/heads/<name> or refs/remotes/origin/<name>), or nil.
      def resolve(ref)
        token = ref.to_s.sub(/\^\{commit\}\z/, "")
        return token if @commits.key?(token)
        return @labels[token] if @labels.key?(token)

        branch = token.delete_prefix("refs/remotes/origin/").delete_prefix("refs/heads/").delete_prefix("origin/")
        @branches[branch]
      end

      def resolve!(ref)
        resolve(ref) || raise(UnknownRef, "unknown simulated ref #{ref.inspect}")
      end

      def ancestors(sha)
        sha = resolve!(sha)
        @ancestors[sha] ||= begin
          seen = Set.new
          stack = [ sha ]
          until stack.empty?
            current = stack.pop
            next unless seen.add?(current)

            stack.concat(@commits.fetch(current).parents)
          end
          seen.freeze
        end
      end

      # True when `ancestor` is reachable from `descendant` (inclusive).
      def ancestor?(ancestor, descendant)
        ancestors(descendant).include?(resolve!(ancestor))
      end

      # The commits reachable from `head` and from none of `exclude`, oldest
      # first -- `git rev-list --topo-order --reverse head ^exclude...`.
      def range(head, exclude: [])
        excluded = Array(exclude).compact.each_with_object(Set.new) { |ref, set| set.merge(ancestors(ref)) }
        (ancestors(head) - excluded).map { |sha| @commits.fetch(sha) }.sort_by { |commit| [ generation(commit.id), commit.id ] }
      end

      def merge_base(a, b)
        common = ancestors(a) & ancestors(b)
        common.max_by { |sha| [ generation(sha), sha ] }
      end

      # Replays `commits` (oldest first) onto `onto`, the way `git rebase` or
      # `git cherry-pick` does. Merge commits are skipped. A commit whose
      # patch the target side already holds is dropped; one whose paths the
      # target side changed with a different patch stops the replay (or, with
      # `resolve: true` -- an agent resolving the conflict -- lands anyway).
      def replay(commits, onto:, resolve: false, keep_redundant: false)
        tip = resolve!(onto)
        applied = []
        dropped = []
        Array(commits).each do |commit|
          commit = @commits.fetch(resolve!(commit.is_a?(Commit) ? commit.id : commit))
          next if commit.merge?

          own_patches = commit.parents.flat_map { |parent| ancestors(parent).to_a }.map { |sha| @commits.fetch(sha).patch }.to_set
          target_side = range(tip, exclude: commit.parents).reject { |change| own_patches.include?(change.patch) }
          if target_side.any? { |change| change.patch == commit.patch }
            next dropped << commit unless keep_redundant
          end

          conflicts = target_side.reject { |change| change.patch == commit.patch }.flat_map { |change| change.paths & commit.paths }.uniq.sort
          if conflicts.any? && !resolve
            return ReplayResult.new(tip: tip, applied: applied, dropped: dropped, conflict: commit, conflicts: conflicts)
          end

          tip = derive!(commit, parent: tip).id
          applied << commit
        end
        ReplayResult.new(tip: tip, applied: applied, dropped: dropped, conflict: nil, conflicts: [])
      end

      # `git rebase --onto <onto> <upstream> <head>` (upstream defaults to
      # onto, as `git rebase <onto>` does).
      def rebase(head:, onto:, upstream: nil, resolve: false)
        replay(range(head, exclude: [ upstream || onto ]), onto: onto, resolve: resolve)
      end

      # Rewrites `branch` onto `onto` (default: where it is based today) and
      # force-pushes it. With patch equivalence the replayed commits keep
      # their patch ids, as a clean rebase does; without it each one gets a
      # new patch on the same paths -- the branch was rebased *and* its own
      # changes were edited, so anything built on the old commits now
      # collides with their rewritten versions.
      def rewrite_branch!(branch, onto: nil, patch_equivalent: true, upstream: nil)
        head = resolve!(branch)
        onto_sha = onto ? resolve!(onto) : nil
        upstream ||= begin
          base = onto_sha || pull_request_for_branch(branch)&.then { |pr| resolve(pr.base_branch) } || resolve(default_branch)
          merge_base(head, base)
        end
        own = range(head, exclude: [ upstream ]).reject(&:merge?)
        tip = onto_sha || resolve!(upstream)
        own.each do |commit|
          patch = patch_equivalent ? commit.patch : "#{commit.patch}~rewritten-#{next_sequence}"
          tip = derive!(commit, parent: tip, patch: patch).id
        end
        set_branch!(branch, tip)
      end

      # Appends a commit to a branch (a teammate's push, main moving).
      def advance_branch!(branch, label: nil, patch: nil, paths: nil)
        tip = commit!(label: label, parents: [ resolve!(branch) ], patch: patch, paths: paths).id
        set_branch!(branch, tip)
      end

      def set_branch!(branch, sha)
        @branches[branch.to_s] = resolve!(sha)
      end

      def delete_branch!(branch)
        @branches.delete(branch.to_s)
      end

      def branch?(branch) = @branches.key?(branch.to_s)

      # ---- local checkouts -------------------------------------------------

      def checkout(key, branch: nil)
        @checkouts[key.to_s] ||= begin
          head = branch && resolve(branch)
          Checkout.new(key: key.to_s, branch: branch&.to_s, head: head, operation: nil)
        end
      end

      def checkout?(key) = @checkouts.key?(key.to_s)

      def checkouts = @checkouts.values

      # ---- pull requests ---------------------------------------------------

      def open_pull_request!(number:, head_branch:, base_branch:, job_key: nil, checks: "passing")
        resolve!(head_branch)
        @pull_requests[number.to_i] = PullRequest.new(
          number: number.to_i, job_key: job_key&.to_s, head_branch: head_branch.to_s, base_branch: base_branch.to_s,
          state: "open", merged: false, merge_commit_sha: nil, synced_base_sha: resolve(base_branch),
          head_sha_at_close: nil, checks: checks.to_s, unknown_reads: 0, blocked: false
        )
      end

      def pull_request(number) = @pull_requests[number.to_i]

      def pull_request_for_branch(branch)
        @pull_requests.values.select(&:open?).find { |pr| pr.head_branch == branch.to_s }
      end

      def pull_request_for_job(job_key)
        @pull_requests.values.reverse.find { |pr| pr.job_key == job_key.to_s }
      end

      def head_sha(pr)
        pr.open? ? resolve(pr.head_branch) : (pr.head_sha_at_close || resolve(pr.head_branch))
      end

      # Called when Syrus (or anyone) pushes the PR's head: GitHub resyncs the
      # PR's recorded base.sha to the base tip at that moment. base.sha does
      # not move when only the base branch advances.
      def pushed!(branch)
        pr = pull_request_for_branch(branch)
        pr.synced_base_sha = resolve(pr.base_branch) if pr
      end

      # GitHub's answer for the PR right now, as [mergeable, mergeable_state].
      def mergeability(pr)
        return [ nil, "unknown" ] unless pr.open?

        if pr.unknown_reads.to_i.positive?
          pr.unknown_reads -= 1
          return [ nil, "unknown" ]
        end

        relation = topology_relation(resolve!(pr.head_branch), resolve!(pr.base_branch))
        return [ false, "dirty" ] if relation == :conflicting
        return [ true, "behind" ] if relation == :behind
        return [ true, "blocked" ] if pr.blocked || pr.checks.to_s != "passing"

        [ true, "clean" ]
      end

      # :up_to_date when head contains base, :behind when merging base in
      # would be clean, :conflicting when it would not.
      def topology_relation(head, base)
        return :up_to_date if ancestor?(base, head)

        theirs = range(head, exclude: [ base ]).reject(&:merge?)
        ours = range(base, exclude: [ head ]).reject(&:merge?)
        their_patches = theirs.map(&:patch).to_set
        our_patches = ours.map(&:patch).to_set
        their_paths = theirs.reject { |commit| our_patches.include?(commit.patch) }.flat_map(&:paths).to_set
        our_paths = ours.reject { |commit| their_patches.include?(commit.patch) }.flat_map(&:paths).to_set
        their_paths.intersect?(our_paths) ? :conflicting : :behind
      end

      # Merges the PR the way GitHub does with the configured merge method,
      # then (with delete_branch_on_merge) deletes its head branch and
      # retargets every open PR that was based on it onto the merged PR's base.
      # `force: true` merges a conflicting PR as if its conflicts had been
      # resolved (an integration branch that already resolved them).
      def merge_pull_request!(number, force: false)
        pr = pull_request(number) || raise(Error, "unknown simulated PR ##{number}")
        raise Error, "PR ##{number} is #{pr.state}" unless pr.open?

        head = resolve!(pr.head_branch)
        base = resolve!(pr.base_branch)
        raise MergeConflict, "PR ##{number} conflicts with #{pr.base_branch}" if !force && topology_relation(head, base) == :conflicting

        merged = case merge_method
        when "merge" then store!(Commit.new(id: derive_sha("merge", base, head), parents: [ base, head ], patch: "merge-##{number}", paths: [], label: nil)).id
        when "squash"
          own = range(head, exclude: [ base ]).reject(&:merge?)
          commit!(parents: [ base ], patch: "squash-##{number}", paths: own.flat_map(&:paths).uniq).id
        else replay(range(head, exclude: [ base ]), onto: base, resolve: true).tip
        end
        set_branch!(pr.base_branch, merged)
        pr.state = "closed"
        pr.merged = true
        pr.merge_commit_sha = merged
        pr.head_sha_at_close = head
        delete_merged_head!(pr) if delete_branch_on_merge
        merged
      end

      def close_pull_request!(number)
        pr = pull_request(number)
        return unless pr&.open?

        pr.head_sha_at_close = resolve(pr.head_branch)
        pr.state = "closed"
      end

      # Commits a change to the PR's base that touches the PR's own paths, so
      # merging the PR conflicts -- what a teammate landing an overlapping
      # change does to an open PR.
      def make_pull_request_dirty!(number, label: nil)
        pr = pull_request(number) || raise(Error, "unknown simulated PR ##{number}")
        paths = range(resolve!(pr.head_branch), exclude: [ resolve!(pr.base_branch) ]).flat_map(&:paths).uniq
        paths = [ "#{pr.head_branch}.txt" ] if paths.empty?
        advance_branch!(pr.base_branch, label: label, patch: "conflicts-with-##{number}-#{next_sequence}", paths: paths)
      end

      # A fresh, deterministic token for naming generated paths.
      def unique_token = next_sequence

      # A compact, comparable picture of everything a poll could observe
      # (compared within one process only).
      def fingerprint
        [
          @branches.sort,
          @pull_requests.values.map { |pr| [ pr.number, pr.state, pr.base_branch, pr.checks, pr.blocked, pr.unknown_reads ] }.sort
        ].hash
      end

      private

      def delete_merged_head!(pr)
        return if pr.head_branch == pr.base_branch

        delete_branch!(pr.head_branch)
        @pull_requests.each_value do |other|
          other.base_branch = pr.base_branch if other.open? && other.base_branch == pr.head_branch
        end
      end

      def derive!(commit, parent:, patch: commit.patch)
        id = derive_sha("replay", commit.id, parent, patch)
        return @commits[id] if @commits.key?(id)

        store!(Commit.new(id: id, parents: [ parent ], patch: patch, paths: commit.paths, label: nil))
      end

      def store!(commit)
        return @commits[commit.id] if @commits.key?(commit.id)

        @commits[commit.id] = commit
        @labels[commit.label] = commit.id if commit.label
        commit
      end

      def generation(sha)
        @generation[sha] ||= begin
          parents = @commits.fetch(sha).parents
          parents.empty? ? 0 : parents.map { |parent| generation(parent) }.max + 1
        end
      end

      def derive_sha(*parts)
        Digest::SHA1.hexdigest([ seed, *parts ].join(":"))
      end

      def next_sequence
        @sequence += 1
      end
    end
  end
end
