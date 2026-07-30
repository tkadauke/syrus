# Defence-in-depth for CVE-2026-66066 when libvips is available.
if defined?(Vips)
  Vips.block_untrusted(true)
end
