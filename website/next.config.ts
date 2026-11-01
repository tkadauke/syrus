import type { NextConfig } from "next";

// Static export for GitHub Pages: `next build` emits a fully static site to
// `out/` with no Node runtime. Consequences of the Pages host:
//   - No server: API routes, `force-dynamic`, and custom headers are gone.
//     Pages can't set response headers, so the old CSP/security headers (which
//     lived on the previous self-hosted server) are dropped here. Pages serves
//     HTTPS with HSTS on custom domains automatically.
//   - Image Optimization needs a server, so images are served unoptimized.
//   - trailingSlash keeps every route as `dir/index.html`, which Pages serves
//     reliably at `/dir/` (and 301s `/dir` → `/dir/`).
const nextConfig: NextConfig = {
  output: "export",
  trailingSlash: true,
  // This app lives in a subdirectory of the Rails product repo, which has its
  // own root lockfile. Pin the tracing root to this dir so Next doesn't infer
  // the repo root (the build always runs from website/).
  outputFileTracingRoot: process.cwd(),
  images: { unoptimized: true },
  reactStrictMode: true,
  // GitHub's hosted runners advertise enough CPUs for Next to fan out more
  // static-generation workers than their memory limit can sustain. Keep the
  // Pages build bounded; uncapped builds are killed with SIGKILL while
  // exporting the documentation routes.
  experimental: { globalNotFound: true, cpus: 1 },
  poweredByHeader: false,
  // Surfaced to the client for the footer build stamp. The Pages workflow
  // injects GIT_SHA / GIT_REF from the triggering commit.
  env: {
    NEXT_PUBLIC_GIT_SHA: process.env.GIT_SHA ?? "dev",
    NEXT_PUBLIC_GIT_REF: process.env.GIT_REF ?? "local",
  },
};

export default nextConfig;
