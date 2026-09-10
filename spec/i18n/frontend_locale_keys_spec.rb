require "rails_helper"
require "json"

RSpec.describe "Frontend locale keys", type: :unit do
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

  it "keeps core frontend JSON locale key trees identical" do
    root = Rails.root.join("app/frontend/i18n/locales")

    failures = parity_failures("core", locale_namespaces(root))

    expect(failures).to be_empty, failures.join("\n")
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
