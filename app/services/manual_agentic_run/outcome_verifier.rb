module ManualAgenticRun
  class OutcomeVerifier
    class VerificationFailed < StandardError; end

    def initialize(workflow, client: nil)
      @workflow = workflow
      @job = workflow.job
      @repository = @job.repository
      @client = client || GithubClient.for(repository: @repository, user: @job.user)
    end

    def verify!
      expected = @workflow.artifact("manual_agentic_run_expected_outcomes") || {}
      evidence = { "verified_at" => Time.current.iso8601, "repository" => @repository.slug }
      verify_branch(expected["remote_branch"], evidence) if expected["remote_branch"].present?
      verify_pull_request(expected["pull_request"], evidence) if expected["pull_request"].present?
      @workflow.set_artifact!("manual_agentic_run_verified_outcomes", evidence)
      evidence
    rescue StandardError => e
      @workflow.set_artifact!("manual_agentic_run_publication_recovery", {
        "recorded_at" => Time.current.iso8601,
        "branch" => @job.branch_name,
        "local_head_sha" => @workflow.runs.where.not(head_sha: nil).order(:id).last&.head_sha,
        "expected_outcomes" => expected,
        "failure" => e.message
      }.compact)
      raise VerificationFailed, "break-glass GitHub outcome verification failed: #{e.message}"
    end

    private

    def verify_branch(expected, evidence)
      name = expected.fetch("name")
      actual = @client.branch_head_sha(@repository.slug, name)
      wanted = expected.fetch("sha")
      wanted = local_head_sha if wanted == "local_head"
      raise "branch #{name} is #{actual || 'missing'}, expected #{wanted}" unless actual == wanted

      evidence["remote_branch"] = { "name" => name, "sha" => actual }
    end

    def local_head_sha
      @workflow.runs.where.not(head_sha: nil).order(:id).last&.head_sha ||
        raise("no local implementation HEAD was recorded")
    end

    def verify_pull_request(expected, evidence)
      number = Integer(expected.fetch("number", @job.pr_number || @job.external_pr_number))
      pr = @client.pull_request(@repository.slug, number, bypass_cache: true)
      comparisons = { "base" => pr.base&.ref, "state" => pr.state }
      %w[base state].each do |key|
        next if expected[key].blank?
        raise "pull request ##{number} #{key} is #{comparisons[key]}, expected #{expected[key]}" unless comparisons[key].to_s == expected[key].to_s
      end
      if expected["labels"].present?
        actual_labels = Array(pr.labels).map { |label| label.respond_to?(:name) ? label.name : label.to_s }
        missing = Array(expected["labels"]) - actual_labels
        raise "pull request ##{number} is missing labels: #{missing.join(', ')}" if missing.any?
        comparisons["labels"] = actual_labels
      end
      if expected["comment_contains"].present?
        comments = @client.pr_issue_comments(@repository.slug, number)
        comment = comments.find { |entry| entry.body.to_s.include?(expected["comment_contains"].to_s) }
        raise "pull request ##{number} has no matching comment" unless comment
        comparisons["comment_id"] = comment.id
      end
      evidence["pull_request"] = comparisons.merge("number" => number)
    end
  end
end
