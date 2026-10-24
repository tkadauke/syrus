require "rails_helper"
require "json"

RSpec.describe "Plugin Runtime frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/plugin_runtime/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "plugin_runtime.json")))
  end

  def flatten(value, prefix = nil)
    value.each_with_object({}) do |(key, child), result|
      path = [prefix, key].compact.join(".")
      child.is_a?(Hash) ? result.merge!(flatten(child, path)) : result[path] = child
    end
  end

  def interpolation_tokens(value)
    value.scan(/{{[^}]+}}/).sort
  end

  it "keeps locale trees and interpolation tokens aligned with English" do
    english = flatten(locale("en"))

    %w[de la].each do |name|
      translated = flatten(locale(name))
      expect(translated.keys).to match_array(english.keys)

      english.each do |key, value|
        expect(interpolation_tokens(translated.fetch(key))).to eq(interpolation_tokens(value)),
          "#{name} interpolation tokens differ for #{key}"
      end
    end
  end

  it "translates filter controls in German and Latin" do
    expect(locale("de")).to include(
      "search" => "Suchen",
      "clear_filters" => "Filter zurücksetzen",
      "filter_service" => "Dienst",
      "filter_min_size" => "Mindestgröße"
    )
    expect(locale("la")).to include(
      "search" => "Quaere",
      "clear_filters" => "Filtra purga",
      "filter_service" => "Ministerium",
      "filter_min_size" => "Magnitudo minima"
    )
  end
end
