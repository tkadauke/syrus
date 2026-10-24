require "rails_helper"
require "json"

RSpec.describe "Theming Tools frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/theming_tools/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "theming_tools.json")))
  end

  def interpolation_tokens(value)
    value.scan(/{{[^}]+}}/).sort
  end

  it "keeps locale keys, plural pairs, and interpolation tokens aligned with English" do
    english = locale("en")

    %w[de la].each do |name|
      translated = locale(name)
      expect(translated.keys).to eq(english.keys)

      english.each do |key, value|
        expect(interpolation_tokens(translated.fetch(key))).to eq(interpolation_tokens(value)),
          "#{name} interpolation tokens differ for #{key}"
      end

      english.keys.grep(/_one\z/).each do |one_key|
        expect(translated).to have_key(one_key.sub(/_one\z/, "_other"))
      end
    end
  end

  it "uses a complete German preview summary and preserves theme identifiers" do
    expect(locale("de")).to include(
      "summary_previewed" => "{{name}} als Vorschau angezeigt (THEME-{{id}})",
      "delete_theme_ref" => "THEME-{{id}} löschen"
    )
  end
end
