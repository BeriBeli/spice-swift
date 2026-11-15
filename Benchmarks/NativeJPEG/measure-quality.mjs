import fs from 'node:fs';
import path from 'node:path';

if (process.argv.length !== 3) throw Error('usage: node measure-quality.mjs OUTPUT_DIRECTORY');
const root = process.argv[2];
const results = JSON.parse(fs.readFileSync(path.join(root, 'results.json')));
for (const c of results.cases) {
  const data = fs.readFileSync(path.join(root, c.name + '.bgra'));
  const stride = c.trials[0].stride;
  if (data.length !== stride * c.height) throw Error('Unexpected decoded geometry');
  let error = 0;
  for (let y = 0; y < c.height; y++) for (let x = 0; x < c.width; x++) {
    const edge = x % 23 < 2 || y % 19 < 2 ? 255 : 0;
    const noise = (Math.imul(x, 1664525) ^ Math.imul(y, 1013904223)) >>> 24;
    const expected = [((Math.floor(x / 64) + Math.floor(y / 64)) & 1 ? noise : x + y) & 255,
      edge ^ Math.floor(y * 255 / c.height), edge ^ Math.floor(x * 255 / c.width)];
    for (let k = 0; k < 3; k++) error += (data[y * stride + x * 4 + k] - expected[k]) ** 2;
  }
  const mse = error / (c.width * c.height * 3);
  c.quality_measurement = {rgb_mse: mse, rgb_psnr_db: mse ? 10 * Math.log10(65025 / mse) : null,
    reference: 'exact RGB generator in jpeg-check.c; alpha excluded; no scaling'};
  console.log(c.name, 'PSNR', c.quality_measurement.rgb_psnr_db?.toFixed(2) ?? 'infinite');
}
fs.writeFileSync(path.join(root, 'results.json'), JSON.stringify(results, null, 2) + '\n');
