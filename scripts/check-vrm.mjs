import { chromium } from 'playwright';

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2 });

const consoleLogs = [];
const pageErrors = [];

page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
page.on('pageerror', err => pageErrors.push(err.message));

console.log('Navigating to http://127.0.0.1:4173/vrm.html ...');
await page.goto('http://127.0.0.1:4173/vrm.html', { waitUntil: 'networkidle' });

// Wait for status to show "就绪 · 运行中"
try {
  await page.waitForFunction(() => {
    const el = document.getElementById('status');
    return el && (el.textContent.includes('就绪') || el.textContent.includes('失败'));
  }, { timeout: 15000 });

  const statusText = await page.locator('#status').textContent();
  console.log('Current Status:', statusText);

  // Wait 3 seconds for animation to play and render
  await page.waitForTimeout(3000);

  // Take screenshot
  await page.screenshot({ path: 'evidence/vrm-preview.png' });
  console.log('Saved screenshot to evidence/vrm-preview.png');

  // Trigger talk button to verify expression and take another screenshot
  await page.click('#btn-talk');
  await page.waitForTimeout(1000);
  await page.screenshot({ path: 'evidence/vrm-talking.png' });
  console.log('Saved screenshot to evidence/vrm-talking.png');

} catch (err) {
  console.error('Wait failed:', err.message);
  await page.screenshot({ path: 'evidence/vrm-error.png' });
} finally {
  console.log('--- Page Console Logs ---');
  console.log(consoleLogs.slice(-20).join('\n'));
  if (pageErrors.length > 0) {
    console.error('--- Page Errors ---');
    console.error(pageErrors.join('\n'));
  }
  await browser.close();
}
