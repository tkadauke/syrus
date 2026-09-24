require "rails_helper"
require "json"

RSpec.describe "Frontend locale keys", type: :unit do
  REFERENCED_CORE_KEYS = {
    "admin" => %w[
      page_title_work_units
      page_title_backend_exceptions
      nav_work_units
      nav_backend_exceptions
      work_units.heading
      work_units.aria
      work_units.description
      work_units.loading
      work_units.error_load
      work_units.refresh
      work_units.refreshing
      work_units.show_user_debug
      work_units.hide_user_debug
      backend_exceptions.heading
      backend_exceptions.aria
      backend_exceptions.loading
      backend_exceptions.error_load
      backend_exceptions.refresh
      backend_exceptions.refreshing
      features.slugs.browser_error_auto_reports.name
    ],
    "common" => %w[
      status.skipped
      blocked_reasons.pr_checks_failing_base_unknown
      blocked_reasons.pr_checks_failing_base_stale
    ],
    "jobs" => %w[
      recheck_pr_checks
      retry_with_agent
      retry_with_agent_feedback
      section_workflows_loading
      section_workflows_load_error
      pr_checks_head_sha
      pr_checks_payload_base_sha
      pr_checks_override_once
      pr_checks_override_confirm
      pr_checks_override_reason
    ],
    "settings" => %w[
      repository.needs_triage_showing_limited
      repository.col_issue
    ]
  }.freeze

  def supported_locales
    %w[en de la]
  end

  def flatten_json(value, prefix = [])
    return { prefix.join(".") => value } unless value.is_a?(Hash)

    value.each_with_object({}) do |(key, child), leaves|
      leaves.merge!(flatten_json(child, prefix + [ key.to_s ]))
    end
  end

  def locale_namespaces(root)
    supported_locales.index_with do |locale|
      Dir.glob(root.join(locale, "*.json")).sort.to_h do |path|
        [ File.basename(path, ".json"), JSON.parse(File.read(path)) ]
      end
    end
  end

  def parity_failures(label, namespaces_by_locale)
    english_namespaces = namespaces_by_locale.fetch("en")

    supported_locales.filter_map do |locale|
      namespaces = namespaces_by_locale.fetch(locale)
      missing_files = english_namespaces.keys.sort - namespaces.keys.sort
      extra_files = namespaces.keys.sort - english_namespaces.keys.sort
      key_failures = (english_namespaces.keys & namespaces.keys).filter_map do |namespace|
        expected = flatten_json(english_namespaces.fetch(namespace)).keys.sort
        actual = flatten_json(namespaces.fetch(namespace)).keys.sort
        missing = expected - actual
        extra = actual - expected
        next if missing.empty? && extra.empty?

        [
          "#{namespace}:",
          ("    missing: #{missing.join(', ')}" if missing.any?),
          ("    extra: #{extra.join(', ')}" if extra.any?)
        ].compact.join("\n")
      end
      next if missing_files.empty? && extra_files.empty? && key_failures.empty?

      [
        "#{label} #{locale}:",
        ("  missing namespace files: #{missing_files.join(', ')}" if missing_files.any?),
        ("  extra namespace files: #{extra_files.join(', ')}" if extra_files.any?),
        key_failures.map { |failure| "  #{failure}" }
      ].flatten.compact.join("\n")
    end
  end

  def dig_key(tree, key)
    key.split(".").reduce(tree) do |value, part|
      return nil unless value.is_a?(Hash)

      value[part]
    end
  end

  it "keeps core frontend JSON locale key trees identical" do
    root = Rails.root.join("app/frontend/i18n/locales")

    failures = parity_failures("core", locale_namespaces(root))

    expect(failures).to be_empty, failures.join("\n")
  end

  it "resolves core locale keys referenced by admin work units, exceptions, jobs, and repository triage UI" do
    root = Rails.root.join("app/frontend/i18n/locales")
    namespaces = locale_namespaces(root)
    failures = supported_locales.flat_map do |locale|
      REFERENCED_CORE_KEYS.flat_map do |namespace, keys|
        tree = namespaces.fetch(locale).fetch(namespace)

        keys.filter_map do |key|
          value = dig_key(tree, key)
          next if value.is_a?(String) && value.present?

          "#{locale}/#{namespace}.#{key}"
        end
      end
    end

    expect(failures).to be_empty, "Missing or blank referenced frontend locale keys:\n#{failures.join("\n")}"
  end

  it "keeps plugin frontend JSON locale key trees identical" do
    failures = Dir.glob(Rails.root.join("plugins/*/app/frontend/i18n/locales")).sort.flat_map do |root_path|
      root = Pathname(root_path)
      plugin_name = root.each_filename.to_a.fetch(1)

      parity_failures("plugin #{plugin_name}", locale_namespaces(root))
    end

    expect(failures).to be_empty, failures.join("\n")
  end
end
