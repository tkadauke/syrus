module AlertmanagerInvestigations
  class Prompt
    def initialize(alert:, runbook:)
      @alert = alert
      @runbook = runbook
    end

    def to_s
      <<~PROMPT
        Investigate the firing Alertmanager alert "#{@alert.alert_name}".

        Alert payload:

        ```json
        #{JSON.pretty_generate(@alert.payload)}
        ```

        Runbook (#{@runbook.repository.slug}:#{@runbook.path} at #{@runbook.ref}):

        ```markdown
        #{@runbook.content}
        ```

        Follow the runbook to investigate and report findings. Do not remediate or actuate.
        If the runbook reaches a point that needs operator action, submit the final
        report with `escalate: true` and the matching `escalation_reason`:
        `needs_human_decision`, `lacks_authority`, `remediation_failed`, or
        `unsafe_to_proceed`.
      PROMPT
    end
  end
end
