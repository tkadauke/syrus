require "rails_helper"
require "json"

RSpec.describe "Credential Store frontend locales", type: :unit do
  def locale(name)
    path = Rails.root.join("plugins/credential_store/app/frontend/i18n/locales/#{name}/credential_store.json")
    JSON.parse(File.read(path))
  end

  def placeholders(value)
    value.scan(/\{\{\s*([^},\s]+).*?\}\}/).flatten.sort
  end

  it "provides translated German and Latin security guidance" do
    expect(locale("de")).to include(
      "description" => "Verschlüsselte allgemeine Anmeldedaten verwalten, ohne geheime Nutzdaten offenzulegen.",
      "form_description" => "Nutzdatenfelder können nur geschrieben werden. Vorhandene geheime Werte werden von der API nie zurückgegeben.",
      "ssh_identity_warning" => "Die Erkennung beweist die Erreichbarkeit, nicht die Serveridentität. Prüfe den Fingerabdruck über einen vertrauenswürdigen Kanal, bevor du ihn bestätigst."
    )
    expect(locale("la")).to include(
      "active" => "Activum",
      "description" => "Credentialia generalia cifrata administra sine materia payload patefacienda.",
      "form_description" => "Campi payload tantum scribi possunt. Valores secreti existentes numquam ab API redduntur.",
      "inactive" => "Inactivum",
      "ssh_not_enrolled" => "Nulla clavis hospitis inscripta est. Chat SSH hoc credentiale nondum adhibere potest."
    )
  end

  it "preserves every English interpolation placeholder in both translations" do
    english = locale("en")

    %w[de la].each do |name|
      translated = locale(name)
      english.each_key do |key|
        next unless english.fetch(key).is_a?(String)

        expect(placeholders(translated.fetch(key))).to eq(placeholders(english.fetch(key))), "#{name}.#{key}"
      end
    end
  end
end
