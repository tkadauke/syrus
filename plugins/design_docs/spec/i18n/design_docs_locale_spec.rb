require "rails_helper"
require "json"

RSpec.describe "Design Docs frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/design_docs/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "design_docs.json")))
  end

  def leaves(value, prefix = nil)
    value.each_with_object({}) do |(key, child), result|
      path = [ prefix, key ].compact.join(".")
      child.is_a?(Hash) ? result.merge!(leaves(child, path)) : result[path] = child
    end
  end

  def placeholders(value)
    value.scan(/\{\{\s*([^},\s]+).*?\}\}/).flatten.sort
  end

  it "uses native German orthography in archive, review, toolbar, section, and confirmation copy" do
    german = leaves(locale("de"))

    expect(german).to include(
      "archived_read_only" => "Dieses Designdokument ist archiviert. Inhalt, Kommentare, Vorschläge und Reviews sind schreibgeschützt.",
      "aria_share_visibility" => "Sichtbarkeit der Freigabe",
      "notice_saved_suggestion" => "Als Vorschlag zur Prüfung durch den Besitzer gespeichert.",
      "threads" => "Diskussionen",
      "toolbar.bulleted_list" => "Aufzählung",
      "viewing_version_read_only" => "Kommentare und Vorschläge mit Stand von v{{number}} werden angezeigt. Schreibgeschützt.",
      "tool_suggested_change_summary" => "Änderung für {{doc}} vorgeschlagen{{state}}",
      "tool_thread" => "Diskussion",
      "tool_no_sections" => "Keine Überschriften gefunden.",
      "tool_confirmation_required" => "Bestätigung erforderlich",
      "tool_state_transition" => "Statusübergang"
    )
  end

  it "keeps every locale leaf and interpolation placeholder aligned with English" do
    english = leaves(locale("en"))

    %w[de la].each do |name|
      translated = leaves(locale(name))

      expect(translated.keys).to eq(english.keys), "#{name} locale keys differ from English"
      english.each_key do |key|
        expect(placeholders(translated.fetch(key))).to eq(placeholders(english.fetch(key))), "#{name}.#{key}"
      end
    end
  end
end
