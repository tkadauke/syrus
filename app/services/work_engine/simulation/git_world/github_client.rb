# frozen_string_literal: true

require "ostruct"

module WorkEngine
  module Simulation
    class GitWorld
      # Answers the GithubClient calls the merge-state poller and the landing
      # gate make, from a GitWorld. Pull requests come back shaped like the
      # Octokit resources production reads (`pr.head.sha`, `pr.base.ref`,
      # `pr.mergeable_state`, ...). Each read recomputes mergeability from the
      # current topology, so a PR turns `dirty` when its base gains an
      # overlapping change and `clean` once a rebase pushed a head that
      # contains the base tip.
      #
      # Calls the model does not cover raise Unmodeled, a StandardError, so
      # production code sees what it sees when GitHub fails (most callers of
      # cosmetic calls -- comments, footers -- rescue and move on); every such
      # call is also reported through `log`, so a scenario that leans on one
      # shows it in its event log instead of silently guessing an answer.
      class GithubClient
        class Unmodeled < StandardError; end

        attr_reader :world, :repository, :calls

        def initialize(world, repository:, log: nil)
          @world = world
          @repository = repository
          @log = log
          @calls = []
        end

        def pull_request(_repo_slug, number, bypass_cache: false)
          calls << [ :pull_request, number.to_i, bypass_cache ]
          pr = world.pull_request(number) || raise(Octokit::NotFound)
          mergeable, mergeable_state = world.mergeability(pr)
          head_sha = world.head_sha(pr)
          OpenStruct.new(
            number: pr.number,
            state: pr.state,
            merged: pr.merged,
            merge_commit_sha: pr.merge_commit_sha,
            mergeable: mergeable,
            mergeable_state: mergeable_state,
            labels: [],
            body: pr.body.to_s,
            head: OpenStruct.new(ref: pr.head_branch, sha: head_sha, repo: repo_resource),
            base: OpenStruct.new(ref: pr.base_branch, sha: pr.synced_base_sha || world.resolve(pr.base_branch), repo: repo_resource)
          )
        end

        def branch_head_sha(_repo_slug, branch)
          calls << [ :branch_head_sha, branch.to_s ]
          world.resolve(branch.to_s.delete_prefix("heads/")) || raise(Octokit::NotFound)
        end

        def pr_commits(_repo_slug, number)
          pr = world.pull_request(number) || raise(Octokit::NotFound)
          head = world.head_sha(pr)
          base = world.resolve(pr.base_branch)
          world.range(head, exclude: [ base ].compact).map do |commit|
            OpenStruct.new(sha: commit.id, commit: OpenStruct.new(committer: OpenStruct.new(date: nil), author: OpenStruct.new(date: nil)))
          end
        end

        def pr_reviews(_repo_slug, _number) = []
        def pr_issue_comments(_repo_slug, _number, since: nil) = []
        def add_issue_comment(_repo_slug, _number, _body, on_behalf_of: nil) = nil
        def clear_api_blocked! = nil
        def mark_api_blocked!(_reason) = nil

        def update_pull_request_body(_repo_slug, number, body)
          pr = world.pull_request(number) || raise(Octokit::NotFound)
          pr.body = body.to_s
          nil
        end

        def update_pull_request_base(_repo_slug, number, base:)
          calls << [ :update_pull_request_base, number.to_i, base.to_s ]
          pr = world.pull_request(number) || raise(Octokit::NotFound)
          raise Octokit::UnprocessableEntity unless world.branch?(base)

          pr.base_branch = base.to_s
          nil
        end

        def close_pull_request(_repo_slug, number)
          calls << [ :close_pull_request, number.to_i ]
          world.close_pull_request!(number)
        end

        def respond_to_missing?(_name, _include_private = false) = false

        def method_missing(name, *_args, **_kwargs)
          message = "the simulated GitHub does not model GithubClient##{name}"
          @log&.call(message)
          raise Unmodeled, message
        end

        private

        def repo_resource
          OpenStruct.new(full_name: repository.slug)
        end
      end
    end
  end
end
