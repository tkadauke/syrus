class MainHealthChangedService
  # Repair-context building extracted from MainHealthChangedService: composing the
  # repair Job's prompt and materializing the summary / CI / grader log attachments
  # that orient the fix agent. Mixed in via include, so it reads the same @repository
  # state, the MAX_*_ATTACHMENT_BYTES constants, and the shared checked_sha /
  # repair_attachment_prefix helpers through the class ancestry.
  module RepairContext
    def fix_job_prompt
      sha = checked_sha
      prefix = repair_attachment_prefix(sha)

      [
        "Main branch health is broken for #{@repository.slug}.",
        "",
        "Default branch: #{@repository.default_branch}",
        "Commit: #{sha}",
        "",
        "Current health:",
        "- CI: #{@repository.ci_health}",
        "- Graders: #{@repository.grader_health}",
        "",
        "Diagnostic logs are attached to this Job and will be materialized in the workflow workspace.",
        "Start by reading tmp/attachments/#{prefix}-summary.md.",
        "Then inspect tmp/attachments/#{prefix}-ci.md and tmp/attachments/#{prefix}-graders.md if they are present.",
        "",
        "Use the attached context first. Identify the root cause from the default-branch CI and/or grader output, " \
        "then push a minimal fix to restore a green main. Do not expand scope beyond repairing main."
      ].join("\n")
    end

    def attach_repair_context!(job)
      sha = checked_sha
      checks = health_checks_for(sha)
      prefix = repair_attachment_prefix(sha)

      attach_text_file!(
        job,
        filename: "#{prefix}-summary.md",
        title: "Main branch repair summary",
        body: build_repair_summary(sha, checks),
        max_bytes: MAX_SUMMARY_ATTACHMENT_BYTES
      )

      ci_body = build_ci_log_attachment(sha, checks)
      if ci_body.present?
        attach_text_file!(
          job,
          filename: "#{prefix}-ci.md",
          title: "Main branch CI diagnostics",
          body: ci_body,
          max_bytes: MAX_CI_ATTACHMENT_BYTES
        )
      end

      grader_body = build_grader_log_attachment(sha, checks)
      if grader_body.present?
        attach_text_file!(
          job,
          filename: "#{prefix}-graders.md",
          title: "Main branch grader diagnostics",
          body: grader_body,
          max_bytes: MAX_GRADER_ATTACHMENT_BYTES
        )
      end
    rescue StandardError => e
      Rails.logger.warn(
        "[MainHealthChangedService] #{@repository.slug} failed to attach main repair context " \
        "to #{job.slug}: #{e.class}: #{e.message}"
      )
    end

    def attach_text_file!(job, filename:, title:, body:, max_bytes:)
      text = truncate_attachment_body(body, max_bytes)
      document = job.job_attachments.build(
        user: job.user,
        kind: "file",
        title: title,
        source_url: "main-health://#{job.id}/#{filename}",
        filename: filename,
        content_type: "text/markdown",
        byte_size: text.bytesize
      )
      document.file.attach(
        io: StringIO.new(text),
        filename: filename,
        content_type: "text/markdown",
        identify: false
      )
      document.save!
    end

    def build_repair_summary(sha, checks)
      lines = [
        "# Main branch repair context",
        "",
        "Repository: #{@repository.slug}",
        "Default branch: #{@repository.default_branch}",
        "Commit: #{sha}",
        "",
        "Current health:",
        "- CI: #{@repository.ci_health}",
        "- Graders: #{@repository.grader_health}",
        "",
        "Attached diagnostics:",
        "- #{repair_attachment_prefix(sha)}-ci.md: CI failure output and GitHub check links, when CI failed.",
        "- #{repair_attachment_prefix(sha)}-graders.md: Syrus grader workflow output, when graders reported a result.",
        "",
        "Recent health checks:"
      ]

      if checks.empty?
        lines << "- No detailed health-check rows were captured for this commit."
      else
        checks.each do |check|
          lines.concat(summary_lines_for(check))
        end
      end

      lines.join("\n")
    end

    def summary_lines_for(check)
      lines = [
        "- #{check.source} at #{check.checked_at.iso8601}: CI=#{check.ci_health || 'unknown'}, Graders=#{check.grader_health || 'unknown'}"
      ]

      failed_checks = Array(check.ci_failed_checks)
      if failed_checks.any?
        failed_checks.each do |failed_check|
          line = "  - CI failed: #{failed_check_name(failed_check)}"
          url = failed_check_url(failed_check)
          line += " (#{url})" if url
          lines << line
        end
      end

      names = Array(check.grader_failed_names).compact_blank
      lines << "  - Grader names: #{names.join(', ')}" if names.any?
      lines << "  - Workflow: #{workflow_label(check.workflow)}" if check.workflow
      lines
    end

    def build_ci_log_attachment(sha, checks)
      sections = checks.select { |check| check.ci_health == "broken" }.flat_map do |check|
        failed_checks = Array(check.ci_failed_checks)
        if failed_checks.empty?
          [ "## CI poll at #{check.checked_at.iso8601}\n\nCI failed, but GitHub did not provide failing check details." ]
        else
          failed_checks.map do |failed_check|
            ci_failed_check_section(check, failed_check)
          end
        end
      end

      return "" if sections.empty?

      [
        "# CI diagnostics for #{@repository.slug}@#{sha}",
        "",
        sections.join("\n\n")
      ].join("\n")
    end

    def ci_failed_check_section(check, failed_check)
      lines = [
        "## #{failed_check_name(failed_check)}",
        "",
        "- Checked at: #{check.checked_at.iso8601}"
      ]
      lines << "- Conclusion: #{failed_check_value(failed_check, 'conclusion')}" if failed_check_value(failed_check, "conclusion")
      lines << "- URL: #{failed_check_url(failed_check)}" if failed_check_url(failed_check)

      summary = failed_check_value(failed_check, "summary")
      if summary.present?
        lines.concat([ "", "### Summary", "", summary ])
      end

      log = failed_check_value(failed_check, "log")
      if log.present?
        lines.concat([ "", "### Log", "", "```text", log, "```" ])
      elsif failed_check_url(failed_check).present?
        lines.concat([ "", "No inline CI log text was available from GitHub's Check Run API. Use the URL above for full logs." ])
      end

      lines.join("\n")
    end

    def build_grader_log_attachment(sha, checks)
      sections = checks.select { |check| check.workflow.present? || Array(check.grader_failed_names).compact_blank.any? }.filter_map do |check|
        grader_check_section(check)
      end

      return "" if sections.empty?

      [
        "# Grader diagnostics for #{@repository.slug}@#{sha}",
        "",
        sections.join("\n\n")
      ].join("\n")
    end

    def grader_check_section(check)
      lines = [
        "## #{workflow_label(check.workflow)}",
        "",
        "- Checked at: #{check.checked_at.iso8601}",
        "- Grader health: #{check.grader_health || 'unknown'}"
      ]
      names = Array(check.grader_failed_names).compact_blank
      lines << "- Grader names: #{names.join(', ')}" if names.any?

      rendered = rendered_grader_output(check)
      if rendered.present?
        lines.concat([ "", rendered ])
      elsif check.workflow
        lines.concat([ "", "No structured grader iteration output was captured on this workflow." ])
      else
        lines.concat([ "", "No workflow was linked to this health-check row." ])
      end

      lines.join("\n")
    end

    def rendered_grader_output(check)
      workflow = check.workflow
      return "" unless workflow

      iterations = Array(workflow.artifact("iterations")).compact
      return "" if iterations.empty?

      Prompts::GradeFailureFeedback.new(
        iterations: iterations,
        intro: "The main-branch health graders captured these results:",
        include_guidance: false,
        include_git_safety: false
      ).to_s
    end

    def workflow_label(workflow)
      return "workflow unavailable" unless workflow

      workflow.respond_to?(:slug) ? workflow.slug : "workflow ##{workflow.id}"
    end
  end
end
