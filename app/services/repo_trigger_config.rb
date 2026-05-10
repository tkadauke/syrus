require "yaml"

class RepoTriggerConfig
  CONFIG_FILE = ".syrus.yml".freeze

  def self.fetch(repository, github_client:)
    content = github_client.file_content_at(repository.slug, CONFIG_FILE, repository.default_branch)
    from_yaml(content&.fetch(:content, nil))
  rescue Psych::SyntaxError => e
    Rails.logger.info("[RepoTriggerConfig] #{repository.slug} ignored invalid #{CONFIG_FILE}: #{e.message}")
    new
  end

  def self.from_yaml(content)
    yaml = content.present? ? (YAML.safe_load(content) || {}) : {}
    yaml = {} unless yaml.is_a?(Hash)
    triggers = yaml.fetch("triggers", {})
    triggers = {} unless triggers.is_a?(Hash)

    new(
      mentions: fetch_bool(triggers, "mentions", "mention", default: true),
      assignments: fetch_bool(triggers, "assignments", "assignment", default: true)
    )
  end

  def self.fetch_bool(hash, *keys, default:)
    key = keys.find { |candidate| hash.key?(candidate) }
    return default unless key

    hash[key] != false
  end

  attr_reader :mentions, :assignments

  def initialize(mentions: true, assignments: true)
    @mentions = mentions
    @assignments = assignments
  end

  def mentions?
    @mentions
  end

  def assignments?
    @assignments
  end
end
