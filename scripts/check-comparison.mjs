import { chromium } from 'playwright';

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2 });

await page.goto('http://127.0.0.1:4173/vrm.html', { waitUntil: 'networkidle' });
await page.waitForFunction(() => {
  const el = document.getElementById('status');
  return el && el.textContent.includes('就绪');
}, { timeout: 15000 });

// 1. Capture whale maid relaxed
await page.waitForTimeout(2000);
await page.screenshot({ path: 'evidence/vrm-whale-relaxed.png' });
console.log('Captured vrm-whale-relaxed.png');

// 2. Switch to DeepSeek-chan (professional VRM)
await page.click('#btn-switch-model');
await page.waitForTimeout(3000);
await page.screenshot({ path: 'evidence/vrm-deepseek-chan.png' });
console.log('Captured vrm-deepseek-chan.png');

await browser.close();
