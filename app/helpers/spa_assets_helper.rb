module SpaAssetsHelper
  def spa_asset_version
    ERB::Util.url_encode(SyrusVersion.current.presence || Rails.application.config.assets.version)
  end

  def spa_stylesheet_link_tags
    append_spa_asset_version(stylesheet_link_tag(:app))
  end

  def spa_javascript_include_tag(source, **options)
    append_spa_asset_version(javascript_include_tag(source, **options))
  end

  def spa_asset_tag(tag)
    append_spa_asset_version(tag)
  end

  # Loads the content-hashed Vite entry by the exact name lazy chunks import
  # it under (see Syrus::ViteEntrypoint). A development checkout that has not
  # run the Vite build yet renders the shell without it, as before.
  def spa_entry_javascript_tag
    spa_javascript_include_tag(Syrus::ViteEntrypoint.current, type: "module")
  rescue Syrus::ViteEntrypoint::Missing => error
    raise if Rails.env.production?

    Rails.logger.warn(error.message)
    nil
  end

  private

  def append_spa_asset_version(tags)
    version = spa_asset_version
    return tags if version.blank?

    tags.to_s.gsub(/(href|src)="([^"]+)"/) do |match|
      attr = Regexp.last_match(1)
      path = Regexp.last_match(2)
      next match unless path.start_with?("/assets/")
      next match if content_hashed_spa_asset_path?(path)

      separator = path.include?("?") ? "&" : "?"
      %(#{attr}="#{path}#{separator}v=#{version}")
    end.html_safe
  end

  # Two builders produce content-hashed filenames here, with different hash
  # alphabets. Propshaft digests are lowercase hex (`tailwind-74e6a7ef.css`).
  # Vite emits base64url hashes, which can contain characters outside hex, and
  # marks those files `.digested` so propshaft keeps the name as-is
  # (`spa-vendor-DuQfn8Z1.digested.css`). Both already change name when their
  # content changes, so appending a revision query string to either only
  # breaks caching across deploys for a file that did not change.
  def content_hashed_spa_asset_path?(path)
    filename = File.basename(path.split(/[?#]/, 2).first)

    filename.include?(".digested.") ||
      filename.match?(/\A.+-[0-9a-f]{8,}(?:\.[^.]+)+\z/i)
  end
end
