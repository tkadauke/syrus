import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { chromium } from "@playwright/test";

const baseUrl = process.env.PRODUCT_MEDIA_BASE_URL || "http://127.0.0.1:3700";
const email = process.env.PRODUCT_MEDIA_EMAIL || "demo@syrus.local";
const password = process.env.PRODUCT_MEDIA_PASSWORD || "password";

const publicDir = path.join(process.cwd(), "public");
const mediaDir = path.join(publicDir, "media");
const tmpDir = path.join(process.cwd(), ".product-media-capture");
const videoDir = path.join(tmpDir, "video");
fs.mkdirSync(mediaDir, { recursive: true });
fs.rmSync(tmpDir, { recursive: true, force: true });
fs.mkdirSync(videoDir, { recursive: true });

function appUrl(route) {
  return new URL(route, baseUrl).toString();
}

async function login(page) {
  await page.goto(appUrl("/session/new"), { waitUntil: "networkidle" });
  await page.getByLabel("Email").fill(email);
  await page.getByLabel("Password").fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(1000);
  if (await page.getByText("Use an existing Syrus account").isVisible().catch(() => false)) {
    throw new Error(`Login failed for ${email}; still on the sign-in page.`);
  }
  await page.goto(appUrl("/dashboard"), { waitUntil: "networkidle" });
  await settle(page);
  if (await page.getByText("Use an existing Syrus account").isVisible().catch(() => false)) {
    throw new Error(`Login failed for ${email}; dashboard redirected to the sign-in page.`);
  }
}

async function settle(page) {
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(900);
}

async function capture(page, route, outputPath, options = {}) {
  await page.goto(appUrl(route), { waitUntil: "networkidle" });
  await settle(page);
  if (await page.getByText("Use an existing Syrus account").isVisible().catch(() => false)) {
    throw new Error(`Capture for ${route} reached the sign-in page instead of the product UI.`);
  }
  if (options.scrollY) {
    await page.evaluate((scrollY) => window.scrollTo(0, scrollY), options.scrollY);
    await page.waitForTimeout(250);
  }
  await page.screenshot({ path: outputPath, fullPage: false });
}

async function main() {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1600, height: 1000 },
    deviceScaleFactor: 1,
    recordVideo: {
      dir: videoDir,
      size: { width: 1600, height: 1000 },
    },
  });
  const page = await context.newPage();

  await login(page);

  await capture(
    page,
    "/chats/1",
    path.join(publicDir, "product-screenshot.png"),
  );
  await capture(
    page,
    "/chats/1",
    path.join(mediaDir, "walkthrough-recording.png"),
  );
  await capture(
    page,
    "/dashboard?subject=job&view=list",
    path.join(mediaDir, "epic-merge-train.png"),
  );
  await capture(
    page,
    "/insights/spending",
    path.join(mediaDir, "spending-audit.png"),
  );

  await page.goto(appUrl("/chats/1"), { waitUntil: "networkidle" });
  await settle(page);
  await page.waitForTimeout(1200);
  await page.goto(appUrl("/dashboard?subject=job&view=list"), { waitUntil: "networkidle" });
  await settle(page);
  await page.waitForTimeout(1200);
  await page.goto(appUrl("/insights/spending"), { waitUntil: "networkidle" });
  await settle(page);
  await page.waitForTimeout(1200);
  await context.close();

  const mobileContext = await browser.newContext({
    viewport: { width: 471, height: 1024 },
    deviceScaleFactor: 1,
    isMobile: true,
    hasTouch: true,
  });
  const mobilePage = await mobileContext.newPage();
  await login(mobilePage);
  await capture(
    mobilePage,
    "/dashboard?subject=job&view=list",
    path.join(publicDir, "product-screenshot-mobile.png"),
    { scrollY: 250 },
  );
  await mobileContext.close();
  await browser.close();

  const recordedVideos = fs
    .readdirSync(videoDir)
    .filter((name) => name.endsWith(".webm"))
    .map((name) => path.join(videoDir, name));
  if (recordedVideos.length === 0) {
    throw new Error("Playwright did not produce a screencast video.");
  }
  const recordedVideo = recordedVideos[0];
  const webmPath = path.join(mediaDir, "syrus-product-screencast.webm");
  const mp4Path = path.join(mediaDir, "syrus-product-screencast.mp4");
  fs.copyFileSync(recordedVideo, webmPath);
  execFileSync("ffmpeg", [
    "-y",
    "-hide_banner",
    "-loglevel",
    "error",
    "-i",
    webmPath,
    "-vf",
    "fps=30,format=yuv420p",
    "-c:v",
    "libx264",
    "-movflags",
    "+faststart",
    mp4Path,
  ]);

  execFileSync("ffmpeg", [
    "-y",
    "-hide_banner",
    "-loglevel",
    "error",
    "-i",
    path.join(publicDir, "product-screenshot.png"),
    "-vf",
    "scale=1200:750:force_original_aspect_ratio=increase,crop=1200:630:0:0",
    "-frames:v",
    "1",
    path.join(publicDir, "og.png"),
  ]);

  fs.writeFileSync(
    path.join(mediaDir, "syrus-product-screencast.vtt"),
    `WEBVTT

00:00.000 --> 00:03.000
Syrus chat shows a shared walkthrough video and the resulting analysis turn.

00:03.000 --> 00:06.000
The related work appears in the real dashboard queue and tracked Job views.

00:06.000 --> 00:09.000
The spending dashboard keeps the run and model-cost trail visible.
`,
  );

  fs.rmSync(tmpDir, { recursive: true, force: true });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
