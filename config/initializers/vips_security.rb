# Defense-in-depth for CVE-2026-66066 when libvips is available.
begin
  require "vips"

  Vips.block_untrusted(true) if Vips.respond_to?(:block_untrusted)
rescue LoadError
  # The application can boot without libvips on hosts that never process variants.
end
