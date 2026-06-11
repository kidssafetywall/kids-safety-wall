#!/usr/bin/env node
// Geocode institutions using Mapbox Geocoding API
// Usage: node geocode-institutions.js <mapbox_token> [maxRequests] [delayMs]

const https = require('https');
const fs = require('fs');
const path = require('path');

const TOKEN = process.argv[2];
if (!TOKEN || !TOKEN.startsWith('pk.')) {
  console.error('Usage: node geocode-institutions.js <mapbox_token> [maxRequests] [delayMs]');
  console.error('Example: node geocode-institutions.js pk.eyJ1... 1000 200');
  process.exit(1);
}

const DATA_DIR = path.join(__dirname, '..', 'data');
const INST_PATH = path.join(DATA_DIR, 'institutions.json');
const CACHE_PATH = path.join(DATA_DIR, 'geocache.json');

const MAX_REQUESTS = parseInt(process.argv[3]) || 2000;
const DELAY_MS = parseInt(process.argv[4]) || 200;

const institutions = JSON.parse(fs.readFileSync(INST_PATH, 'utf8').replace(/^﻿/, ''));
let cache = {};
if (fs.existsSync(CACHE_PATH)) {
  cache = JSON.parse(fs.readFileSync(CACHE_PATH, 'utf8'));
}

// Prioritize institutions with events
institutions.sort((a, b) => {
  const sa = (a.penalties || 0) + (a.news || 0) + (a.pending || 0);
  const sb = (b.penalties || 0) + (b.news || 0) + (b.pending || 0);
  return sb - sa;
});

function buildQuery(inst) {
  const city = (inst.city || '').replace('臺', '台');
  const addr = inst.address || '';

  if (addr.length > 4) {
    // Address already includes city name — use as-is
    // Strip floor/unit suffixes that confuse geocoders (1樓, 2樓, 1、2樓…)
    return addr.replace(/[\d、,，\s]+[樓層].*$/g, '').trim();
  }

  return `${city}${inst.district || ''} ${inst.name}`;
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

function mapboxSearch(query) {
  return new Promise(resolve => {
    const encoded = encodeURIComponent(query);
    const url = `https://api.mapbox.com/geocoding/v5/mapbox.places/${encoded}.json?access_token=${TOKEN}&country=TW&language=zh-TW&limit=1&types=address,poi`;
    const req = https.get(url, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try {
          const body = JSON.parse(data);
          if (body.features && body.features.length > 0) {
            const [lng, lat] = body.features[0].center;
            if (lat > 21 && lat < 27 && lng > 118 && lng < 123) {
              resolve({ lat, lng, place: body.features[0].place_name });
              return;
            }
          }
        } catch (_) {}
        resolve(null);
      });
    });
    req.on('error', () => resolve(null));
    req.setTimeout(15000, () => { req.destroy(); resolve(null); });
  });
}

function saveCache() {
  fs.writeFileSync(CACHE_PATH, JSON.stringify(cache, null, 2), 'utf8');
}

async function main() {
  const todo = institutions.filter(i => i.key && !cache[i.key]);
  const cached = Object.keys(cache).length;
  const runCount = Math.min(MAX_REQUESTS, todo.length);
  console.log(`Total: ${institutions.length} | Cached: ${cached} | Todo: ${todo.length}`);
  console.log(`This run: up to ${runCount} requests at ${DELAY_MS}ms (~${Math.round(runCount * DELAY_MS / 60000)} min)\n`);

  let queued = 0, geocoded = 0, failed = 0;

  for (const inst of todo) {
    if (queued >= MAX_REQUESTS) break;
    queued++;

    const query = buildQuery(inst);
    const result = await mapboxSearch(query);

    if (result) {
      cache[inst.key] = { lat: result.lat, lng: result.lng };
      geocoded++;
      if (geocoded % 20 === 0) saveCache();
      console.log(`[OK] ${inst.name} → ${result.lat.toFixed(5)}, ${result.lng.toFixed(5)}`);
    } else {
      failed++;
      process.stdout.write('.');
    }

    await sleep(DELAY_MS);
  }

  saveCache();
  const remaining = todo.length - queued;
  console.log(`\n\n==============================`);
  console.log(`  Queried  : ${queued}`);
  console.log(`  Geocoded : ${geocoded}`);
  console.log(`  Failed   : ${failed}`);
  console.log(`  Remaining: ${remaining}`);
  console.log(`  Cache    : ${Object.keys(cache).length} total`);
  console.log(`==============================`);
  if (remaining > 0) console.log(`Run again to geocode next batch.`);
  console.log(`\nNext step: run update-data.ps1 then publish-news.bat to deploy.`);
}

main().catch(console.error);
