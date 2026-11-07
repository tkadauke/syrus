class Coworkers::ReviewPresentationContributor
  include Syrus::Plugin::ReviewPresentationContributor

  def self.target_editors
    [ contribution("target_editor", "CoworkerTargetEditor", "review_target_editor") ]
  end

  def self.evidence_renderers
    [ contribution("evidence", "ReviewEvidence", "review_evidence") ]
  end

  def self.audit_renderers
    [ contribution("audit", "ReviewAudit", "review_audit") ]
  end

  def self.settings_summaries
    [ contribution("settings", "ReviewSettingsSummary", "review_settings") ]
  end

  def self.translation_namespaces = [ "coworkers" ]

  def self.contribution(key, component, copy_key)
    {
      key: "coworkers.#{key}", component: "coworkers/#{component}", target_type: "coworker",
      label_key: "coworkers:#{copy_key}.label", description_key: "coworkers:#{copy_key}.description",
      aria_label_key: "coworkers:#{copy_key}.aria_label"
    }
  end
  private_class_method :contribution
end
