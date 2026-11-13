// app_icon.svg から AppIcon.png（1024・透明なし）と BrandMark.png（512）を作る。
// 使い方：node tools/icon/render.js（Playwright の Chromium が要る）
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

(async () => {
  const here = __dirname;
  const svg = fs.readFileSync(path.join(here, 'app_icon.svg'), 'utf8');
  const assets = path.join(here, '..', '..', 'App', 'Resources', 'Assets.xcassets');
  const browser = await chromium.launch();
  for (const [size, out] of [[1024, 'AppIcon.appiconset/AppIcon.png'], [512, 'BrandMark.imageset/BrandMark.png']]) {
    const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
    await page.setContent(`<html><body style="margin:0;background:#000">${svg.replace('width="1024" height="1024"', `width="${size}" height="${size}"`)}</body></html>`);
    await page.screenshot({ path: path.join(assets, out), clip: { x: 0, y: 0, width: size, height: size }, omitBackground: false, type: 'png' });
    await page.close();
  }
  await browser.close();
  console.log('作りました：AppIcon.png・BrandMark.png');
})();
