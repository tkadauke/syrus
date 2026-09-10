require "rails_helper"

RSpec.describe "Untranslated source strings", type: :unit do
  # Run with:
  #   BUNDLE_PATH="$PWD/vendor/bundle" BUNDLE_APP_CONFIG="$PWD/.bundle" bundle exec rspec spec/i18n
  #
  # This is a deliberately conservative audit for obvious user-visible string
  # literals. It ignores tests, logs, routes, code-like tokens, and existing
  # localized surfaces. Add narrow allowlist entries for legacy debt only; new
  # product copy should move into Rails YAML or frontend/plugin JSON locales.

  def source_globs
    %w[
      app/frontend/**/*.tsx
      app/views/**/*.erb
      plugins/*/app/frontend/**/*.tsx
    ]
  end

  def excluded_path_patterns
    [
      %r{/spec/},
      %r{\.test\.tsx$},
      %r{/i18n/locales/},
      %r{app/frontend/pluginWorkspaceTabs\.tsx$},
      %r{app/frontend/routes/DesignSystem\.tsx$}
    ]
  end

  def legacy_untranslated_paths
    [
      %r{app/frontend/components/(AdminEventActions|Checkbox|FilterBar|ShortcutsHelpModal)\.tsx$},
      %r{app/frontend/components/credentials/},
      %r{app/frontend/components/diff/ReviewableDiff\.tsx$},
      %r{app/frontend/routes/(AdminInvitations|AdminQueue|AdminStuck|AdminTranscript|AdminWorkUnits|AppChromeV2|Chat|Repositories|RepositoryDetail|Tags)\.tsx$},
      %r{app/frontend/routes/appChromeV2/},
      %r{app/frontend/routes/chat/},
      %r{app/frontend/routes/jobDetail/(SourceBrowser|WorkflowGraph)\.tsx$},
      %r{app/frontend/routes/repositoryDetail/DeliveryTracks\.tsx$},
      %r{app/frontend/routes/ThemesSettings\.tsx$},
      %r{app/views/admin/github_app/},
      %r{plugins/.*/app/frontend/}
    ]
  end

  def product_and_provider_names
    %w[
      Claude
      Codex
      GitHub
      MySQL
      OpenAI
      PR
      PDF
      Rails
      SQL
      Syrus
    ]
  end

  def code_like_text
    /
    \A(?:[a-z0-9_.\/:-]+|[A-Z0-9_]+)\z
    |[{};=?]
    |\b(?:Array|Pick|Promise|Record|ReturnType|Set)\b
    /x
  end

  def source_paths
    source_globs.flat_map { |pattern| Dir.glob(Rails.root.join(pattern)) }
      .sort
      .uniq
      .reject { |path| excluded_path_patterns.any? { |pattern| path.match?(pattern) } }
  end

  def allowed_literal?(path, text)
    return true if product_and_provider_names.include?(text)
    return true if text.match?(code_like_text)
    return true if legacy_untranslated_paths.any? { |pattern| path.match?(pattern) }

    false
  end

  def normalized(text)
    text.gsub(/\s+/, " ").strip
  end

  def findings_for(path)
    File.readlines(path).flat_map.with_index(1) do |line, line_number|
      findings = []

      line.scan(/>([^<>{}\n]*[A-Za-z][^<>{}\n]*)</) do |match|
        text = normalized(match.first)
        next if text.length < 3 || allowed_literal?(path, text)

        findings << "#{path.delete_prefix("#{Rails.root}/")}:#{line_number} JSX text: #{text.inspect}"
      end

      line.scan(/(?:aria-label|title|placeholder)="([^"]*[A-Za-z][^"]*)"/) do |match|
        text = normalized(match.first)
        next if text.length < 3 || allowed_literal?(path, text)

        findings << "#{path.delete_prefix("#{Rails.root}/")}:#{line_number} JSX attribute: #{text.inspect}"
      end

      findings
    end
  end

  it "keeps obvious user-visible literals out of source files" do
    findings = source_paths.flat_map { |path| findings_for(path) }

    expect(findings).to be_empty, <<~MESSAGE
      Found untranslated user-visible strings. Move the copy into locale files or add a narrow allowlist for non-user-visible/product/code text:
      #{findings.join("\n")}
    MESSAGE
  end
end
