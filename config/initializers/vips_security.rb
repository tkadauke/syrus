# Defense-in-depth for CVE-2026-66066 when libvips is available.
#
# macOS workers never process images and keep libvips out of the process
# entirely (bin/macos-worker sets SYRUS_LIBVIPS=disabled): the only libvips on
# such a host is a shared Homebrew one that other accounts can upgrade.
return if ENV["SYRUS_LIBVIPS"] == "disabled"

begin
  require "vips"

  Vips.block_untrusted(true) if Vips.respond_to?(:block_untrusted)
rescue LoadError
  # The application can boot without libvips on hosts that never process variants.
end
