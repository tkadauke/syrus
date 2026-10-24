require "rails_helper"
require "json"

RSpec.describe "Scheduled Tasks frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/scheduled_tasks/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "scheduled_tasks.json")))
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

  it "translates scheduled-task copy without renaming protocol tokens" do
    expect(locale("de")).to include(
      "tool_col_task" => "Aufgabe",
      "tool_repository" => "Repository",
      "tool_utc_time" => "UTC: {{time}}"
    )
  end
end
