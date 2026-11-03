// Optional browser check: uses an installed Playwright and Chromium, without an npm build chain.
const { chromium } = require("playwright");
const fs = require("node:fs/promises");
const path = require("node:path");
async function main() {
  const base = process.env.SCREEN_TEST_URL || "http://127.0.0.1:8788";
  const image = process.env.SCREEN_TEST_IMAGE;
  if (!image)
    throw new Error("Set SCREEN_TEST_IMAGE to an OCR-readable screenshot.");
  const output =
    process.env.SCREEN_SCREENSHOTS || path.resolve("artifacts/screenshots");
  await fs.mkdir(output, { recursive: true });
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_PATH || "/usr/bin/chromium",
    headless: true,
    args: ["--no-sandbox"],
  });
  try {
    const context = await browser.newContext({
      viewport: { width: 1440, height: 1000 },
    });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(base);
    await page.getByText("已连接 · 内容保存在本机").waitFor();
    await page.screenshot({
      path: path.join(output, "desktop-before.png"),
      fullPage: true,
    });
    await page.locator("#new-run").click();
    await page.locator("#collection-title").fill("验证样例 · 世界书阅读笔记");
    await page.locator("#create-form button[type=submit]").click();
    await page.locator("#drop-zone").waitFor({ state: "visible" });
    await page.locator("#file-input").setInputFiles(image);
    await page.waitForFunction(
      () =>
        document.querySelector("#document-text").textContent.includes("世界书"),
      null,
      { timeout: 30000 },
    );
    await page.screenshot({
      path: path.join(output, "desktop-document.png"),
      fullPage: true,
    });
    await page.locator("[data-tab=evidence]").click();
    await page.locator("#frame-text").waitFor({ state: "visible" });
    await page
      .locator("#frame-text")
      .fill("世界书配置笔记\n通过浏览器校对保存\n浏览器验收独立关键词");
    await page.locator("#save-text").click();
    await page.getByText("校对已保存，原识别记录仍然保留。").waitFor();
    await page.screenshot({
      path: path.join(output, "desktop-evidence.png"),
      fullPage: true,
    });
    await page.locator("#search").fill("验收独立关键词");
    await page.locator("#search-form button").click();
    await page.locator(".search-hit").first().waitFor();
    await page.locator(".search-hit").first().click();
    await page.locator("#frame-text").waitFor({ state: "visible" });
    if (
      !(await page.locator("#frame-text").inputValue()).includes("浏览器验收")
    )
      throw new Error("Search did not open corrected evidence");
    const downloadPromise = page.waitForEvent("download");
    await page.locator("#export").click();
    const download = await downloadPromise;
    await download.saveAs(path.join(output, "browser-export.zip"));
    await page.setViewportSize({ width: 390, height: 844 });
    await page.waitForFunction(
      () =>
        document.getElementById("sidebar").getBoundingClientRect().right <= 1,
    );
    await page.screenshot({
      path: path.join(output, "mobile.png"),
      fullPage: true,
    });
    await page.locator("#menu").click();
    await page.locator("#sidebar.open").waitFor();
    await page.locator("#menu").click();
    await page.waitForFunction(
      () =>
        document.getElementById("sidebar").getBoundingClientRect().right <= 1,
    );
    if (
      await page.evaluate(
        () => document.documentElement.scrollWidth > window.innerWidth + 2,
      )
    )
      throw new Error("Mobile horizontal overflow");
    if (errors.length) throw new Error(errors.join("\n"));
    console.log(
      "PASS browser create/import/real OCR/correct/search/open/export, desktop and mobile layouts",
    );
    console.log(output);
  } finally {
    await browser.close();
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
