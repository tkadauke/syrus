module Steps
  # Final step: land the graded integration branch into the base in a
  # SINGLE atomic merge, then reconcile the child PRs. Because the merge
  # is atomic, child PR head SHAs are not ancestors of base — the child
  # PRs are closed (not "merged" on GitHub) with a back-link, and their
  # Jobs are marked closed/pr_merged. See docs/plans/landing-merge-train.md.
  class MergeTrainLand < Base
    include MergeTrainStep

    def call
      train = merge_train
      client = GithubClient.for(repository: repository, user: job.user)

      integration_sha = push_integration_branch(train, client)
      train.update!(integration_sha: integration_sha, state: "landing")

      pr = client.create_pull_request(
        repository.slug,
        base: train.base_branch,
        head: train.integration_branch,
        title: integration_pr_title(train),
        body: integration_pr_body(train)
      )

      merge = client.merge_pull_request(
        repository.slug,
        pr.number,
        commit_title: "Merge Epic ##{epic.id} via Syrus merge-train",
        merge_method: "merge"
      )
      merged = merge.respond_to?(:merged) ? merge.merged : merge[:merged]
      raise StepFailed, "merge_train: GitHub did not report the integration PR as merged" unless merged

      client.delete_branch(repository.slug, train.integration_branch)
      reconcile_members!(train, client, pr)

      train.update!(state: "succeeded", finished_at: Time.current)
      log("merge_train: landed Epic ##{epic.id} (#{train.members.size} PR(s)) via integration PR ##{pr.number}")
    end

    private

    def push_integration_branch(train, client)
      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      push_url = repository.authenticated_push_url(client.access_token)
      git.run("push", "--force-with-lease", push_url, "HEAD:refs/heads/#{train.integration_branch}", chdir: chdir)
      git.run("rev-parse", "HEAD", chdir: chdir).strip
    end

    def reconcile_members!(train, client, integration_pr)
      train.members.includes(:job).each do |member|
        member_job = member.job
        if member_job.pr_number.present?
          client.add_issue_comment(
            repository.slug,
            member_job.pr_number,
            "Landed via Epic merge-train (integration PR ##{integration_pr.number}). #{member_job.slug}."
          )
          client.close_pull_request(repository.slug, member_job.pr_number)
        end
        member_job.close_with_reason!("pr_merged") if member_job.open?
        if member_job.branch_name.present?
          client.delete_branch(repository.slug, member_job.branch_name)
          member_job.update_column(:branch_deleted_at, Time.current)
        end
        member.update!(state: "merged")
      end
    end

    def integration_pr_title(train)
      label = epic.respond_to?(:number) && epic.number ? "Epic ##{epic.number}" : "Epic ##{epic.id}"
      "Land #{label}: #{epic.title}".strip
    end

    def integration_pr_body(train)
      lines = [ "Atomic Epic landing via Syrus merge-train.", "", "Members:" ]
      train.members.includes(:job).each do |member|
        member_job = member.job
        ref = member_job.pr_number.present? ? "##{member_job.pr_number}" : member_job.slug
        lines << "- #{ref} (#{member_job.branch_name})"
      end
      lines.join("\n")
    end
  end
end
