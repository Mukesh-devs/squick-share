// Renders scripts/website-og.html to website/assets/og.png (1200 × 630).
// node scripts/website-og.mjs   (Playwright: npm install --no-save playwright && npx playwright install chromium)
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { chromium } from "playwright";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const browser = await chromium.launch(process.env.PW_CHANNEL ? { channel: process.env.PW_CHANNEL } : {});
const page = await browser.newPage({ viewport: { width: 1200, height: 630 } });
await page.goto(pathToFileURL(join(root, "scripts/website-og.html")).href);
await page.evaluate(() => document.fonts.ready);
await page.waitForLoadState("networkidle");
await page.screenshot({ path: join(root, "website/assets/og.png") });
await browser.close();
console.log("wrote website/assets/og.png");
