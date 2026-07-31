# Defence-in-depth for CVE-2026-66066 when libvips is available.
if defined?(Vips) && Vips.respond_to?(:block_untrusted)
  Vips.block_untrusted(true)
end
