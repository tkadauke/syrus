require "rails_helper"
require "yaml"

RSpec.describe "Backend locale keys", type: :unit do
  def supported_locales
    %w[en de la]
  end

  def plural_keys
    %w[zero one two few many other]
  end

  def locale_tree(locale)
    YAML.load_file(Rails.root.join("config/locales/#{locale}.yml"), aliases: true).fetch(locale)
  end

  def flatten_leaves(value, prefix = [])
    return { prefix.join(".") => value } unless value.is_a?(Hash)

    value.each_with_object({}) do |(key, child), leaves|
      leaves.merge!(flatten_leaves(child, prefix + [ key.to_s ]))
    end
  end

  def pluralization_key?(key)
    plural_keys.include?(key.split(".").last)
  end

  def interpolation_names(value)
    return [] unless value.is_a?(String)

    value.scan(/%\{([^}]+)\}/).flatten.sort
  end

  def interpolation_args(names)
    names.index_with do |name|
      case name
      when "count"
        2
      when "date"
        "2026-09-10"
      when "email"
        "user@example.com"
      when "number"
        42
      when "time"
        "2 hours"
      else
        "test"
      end
    end.symbolize_keys
  end

  let(:trees) { supported_locales.index_with { |locale| locale_tree(locale) } }
  let(:leaves_by_locale) { trees.transform_values { |tree| flatten_leaves(tree) } }
  let(:english_leaves) { leaves_by_locale.fetch("en") }

  it "keeps en, de, and la backend locale key trees identical" do
    expected_keys = english_leaves.keys.sort

    failures = supported_locales.filter_map do |locale|
      keys = leaves_by_locale.fetch(locale).keys.sort
      missing = expected_keys - keys
      extra = keys - expected_keys
      next if missing.empty? && extra.empty?

      [
        "#{locale}:",
        ("  missing: #{missing.join(', ')}" if missing.any?),
        ("  extra: #{extra.join(', ')}" if extra.any?)
      ].compact.join("\n")
    end

    expect(failures).to be_empty, failures.join("\n")
  end

  it "keeps interpolation placeholders identical to English" do
    failures = supported_locales.reject { |locale| locale == "en" }.flat_map do |locale|
      leaves = leaves_by_locale.fetch(locale)

      english_leaves.filter_map do |key, english_value|
        next unless leaves.key?(key)

        expected = interpolation_names(english_value)
        actual = interpolation_names(leaves.fetch(key))
        next if expected == actual

        "#{locale}.#{key}: expected placeholders #{expected.inspect}, found #{actual.inspect}"
      end
    end

    expect(failures).to be_empty, failures.join("\n")
  end

  it "resolves every backend translation without MissingTranslation" do
    failures = leaves_by_locale.flat_map do |locale, leaves|
      leaves.filter_map do |key, value|
        next if pluralization_key?(key)

        args = interpolation_args(interpolation_names(value))
        args[:count] ||= 2 if value.is_a?(String) && key.split(".").last == "other"

        I18n.t(key, locale: locale, raise: true, **args)
        nil
      rescue I18n::MissingTranslationData, I18n::MissingInterpolationArgument => error
        "#{locale}.#{key}: #{error.message}"
      end
    end

    expect(failures).to be_empty, failures.join("\n")
  end

  it "pluralizes repository retry messages correctly" do
    expect(I18n.t("api.repositories.retry_enqueued", count: 1, provider: "Claude")).to eq("Retry enqueued for 1 failed job with Claude.")
    expect(I18n.t("api.repositories.retry_enqueued", count: 3, provider: "Claude")).to eq("Retry enqueued for 3 failed jobs with Claude.")
    expect(I18n.t("api.repositories.bulk_delegated", count: 1)).to eq("1 issue delegated to Syrus.")
    expect(I18n.t("api.repositories.bulk_delegated", count: 5)).to eq("5 issues delegated to Syrus.")
    expect(I18n.t("api.repositories.bulk_closed", count: 1)).to eq("1 issue closed.")
    expect(I18n.t("api.repositories.bulk_closed", count: 3)).to eq("3 issues closed.")
  end

  it "localizes German inclusion validation errors for user agent providers" do
    message = I18n.with_locale(:de) do
      user = User.new(email_address: "user@example.com", password: "supersecret", agent_provider: "oracle")
      user.validate
      user.errors.full_messages_for(:agent_provider).first
    end

    expect(message).to include("ist kein gültiger Wert")
    expect(message).not_to include("Translation missing")
  end
end
