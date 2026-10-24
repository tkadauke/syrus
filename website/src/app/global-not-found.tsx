import "./globals.css";
import { chromeFor } from "@/lib/chrome";

export default function GlobalNotFound() {
  const copy = chromeFor("en").notFound;

  return (
    <html lang="en">
      <body>
        <main className="wrap flex min-h-screen flex-col items-center justify-center text-center">
          <p className="font-mono text-sm uppercase tracking-[0.16em] text-cream-faint">404</p>
          <h1 className="mt-4 text-4xl font-semibold text-cream">{copy.title}</h1>
          <a className="mt-6 text-clay underline underline-offset-4" href="/">
            {copy.home}
          </a>
        </main>
      </body>
    </html>
  );
}
