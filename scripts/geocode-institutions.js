#!/usr/bin/env node
// Geocode institutions — supports Mapbox (fast) or Nominatim/OSM (free, no token)
// Usage (Mapbox):    node geocode-institutions.js <pk.xxx token> [maxRequests] [delayMs]
// Usage (Nominatim): node geocode-institutions.js --osm            [maxRequests] [delayMs]

const https = require('https');
const fs = require('fs');
const path = require('path');

const arg1 = process.argv[2] || '';
const USE_OSM = arg1 === '--osm';
const TOKEN = USE_OSM ? null : arg1;

if (!USE_OSM && (!TOKEN || !TOKEN.startsWith('pk.'))) {
  console.error('Usage (Mapbox):    node geocode-institutions.js <pk.xxx> [maxRequests] [delayMs]');
  console.error('Usage (Nominatim): node geocode-institutions.js --osm    [maxRequests] [delayMs]');
  process.exit(1);
}

const DATA_DIR = path.join(__dirname, '..', 'data');
const INST_PATH = path.join(DATA_DIR, 'institutions.json');
const CACHE_PATH = path.join(DATA_DIR, 'geocache.json');

// Nominatim requires >= 1100ms between requests per usage policy
const DEFAULT_DELAY = USE_OSM ? 1100 : 200;
const MAX_REQUESTS = parseInt(process.argv[3]) || (USE_OSM ? 200 : 2000);
const DELAY_MS = parseInt(process.argv[4]) || DEFAULT_DELAY;

const institutions = JSON.parse(fs.readFileSync(INST_PATH, 'utf8').replace(/^﻿/, ''));
let cache = {};
if (fs.existsSync(CACHE_PATH)) {
  cache = JSON.parse(fs.readFileSync(CACHE_PATH, 'utf8'));
}

// Prioritize: 1) institutions with events, 2) institutions with address (higher geocode success)
institutions.sort((a, b) => {
  const sa = (a.penalties || 0) + (a.news || 0) + (a.pending || 0);
  const sb = (b.penalties || 0) + (b.news || 0) + (b.pending || 0);
  if (sb !== sa) return sb - sa;
  const ha = (a.address && a.address.length > 4) ? 1 : 0;
  const hb = (b.address && b.address.length > 4) ? 1 : 0;
  return hb - ha;
});

function convertChineseNumerals(str) {
  const d = { 一: '1', 二: '2', 三: '3', 四: '4', 五: '5', 六: '6', 七: '7', 八: '8', 九: '9', 〇: '0' };
  // X十Y → X*10+Y  (e.g. 三十一 → 31)
  str = str.replace(/([一二三四五六七八九])十([一二三四五六七八九])/g, (_, a, b) => String(parseInt(d[a]) * 10 + parseInt(d[b])));
  str = str.replace(/([一二三四五六七八九])十/g, (_, a) => String(parseInt(d[a]) * 10));
  str = str.replace(/十([一二三四五六七八九])/g, (_, b) => String(10 + parseInt(d[b])));
  str = str.replace(/十/g, '10');
  // Remaining single CJK digits (e.g. 一一八 → 118)
  return str.replace(/[一二三四五六七八九〇]/g, c => d[c] || c);
}

function buildQuery(inst) {
  const city = (inst.city || '').replace(/臺/g, '台');
  let addr = (inst.address || '').replace(/臺/g, '台');

  if (addr.length > 4) {
    // Convert Chinese numerals to Arabic so geocoders can match them (e.g. 三十一巷 → 31巷)
    addr = convertChineseNumerals(addr);
    // Strip 里/村 + 鄰 subdivisions (e.g. 廣興里7鄰, 南昌村18鄰) — geocoders don't understand them.
    // Capture the preceding 區/鎮/鄉 so it is preserved; only the 里/村 sub-name is removed.
    addr = addr.replace(/([區鎮鄉])[一-鿿]{1,4}[里村]\d+鄰\s*/g, '$1');
    // Keep only up to the first 號 — strips multiple addresses and floor info after it
    const firstHao = addr.indexOf('號');
    if (firstHao !== -1) addr = addr.slice(0, firstHao + 1);
    // Collapse enumerated sub-numbers before 號 (e.g. 23之1、23之2號 → 23之1號)
    addr = addr.replace(/([\d之\w-]+)[、，,.;；][\d之\w、，,.;；-]+號$/, '$1號');
    return addr.trim();
  }

  return `${city}${inst.district || ''} ${inst.name}`;
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

function httpGet(url, headers) {
  return new Promise(resolve => {
    const opts = { headers: headers || {} };
    const req = https.get(url, opts, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => resolve(data));
    });
    req.on('error', () => resolve(null));
    req.setTimeout(15000, () => { req.destroy(); resolve(null); });
  });
}

function inTaiwan(lat, lng) {
  return lat > 21 && lat < 27 && lng > 118 && lng < 123;
}

async function mapboxSearch(query) {
  const url = `https://api.mapbox.com/geocoding/v5/mapbox.places/${encodeURIComponent(query)}.json?access_token=${TOKEN}&country=TW&language=zh-TW&limit=1&types=address,poi`;
  const raw = await httpGet(url);
  if (!raw) return null;
  try {
    const body = JSON.parse(raw);
    if (body.features && body.features.length > 0) {
      const [lng, lat] = body.features[0].center;
      if (inTaiwan(lat, lng)) return { lat, lng };
    }
  } catch (_) {}
  return null;
}

// Build a road-level fallback query (strip 巷/弄/號 suffixes)
function buildRoadQuery(addr) {
  // Strip from the first 巷/弄 or from the number after the road name
  let road = addr.replace(/[巷弄].*/g, '').replace(/\d+號.*$/, '').trim();
  // Remove trailing digits that are just stray number fragments
  road = road.replace(/\d+$/, '').trim();
  return road;
}

async function nominatimGet(query) {
  const url = `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(query)}&format=json&countrycodes=tw&limit=1&accept-language=zh-TW`;
  const raw = await httpGet(url, {
    'User-Agent': 'kids-safety-wall/1.0 (https://github.com/kidssafetywall/kids-safety-wall)'
  });
  if (!raw) return null;
  try {
    const body = JSON.parse(raw);
    if (Array.isArray(body) && body.length > 0) {
      const lat = parseFloat(body[0].lat);
      const lng = parseFloat(body[0].lon);
      if (inTaiwan(lat, lng)) return { lat, lng };
    }
  } catch (_) {}
  return null;
}

async function nominatimSearch(query) {
  // First try the full address query
  const result = await nominatimGet(query);
  if (result) return result;

  // Fall back to road-level query (strip house number and alley details)
  const roadQuery = buildRoadQuery(query);
  if (roadQuery && roadQuery !== query && roadQuery.length > 5) {
    await sleep(DELAY_MS);
    return nominatimGet(roadQuery);
  }
  return null;
}

const search = USE_OSM ? nominatimSearch : mapboxSearch;

function saveCache() {
  fs.writeFileSync(CACHE_PATH, JSON.stringify(cache, null, 2), 'utf8');
}

async function main() {
  const provider = USE_OSM ? 'Nominatim/OSM (free)' : 'Mapbox';
  // Skip only entries with a valid coordinate object; null/missing entries are retried
  const todo = institutions.filter(i => i.key && !cache[i.key]);
  const cached = Object.keys(cache).length;
  const runCount = Math.min(MAX_REQUESTS, todo.length);
  console.log(`Provider: ${provider}`);
  console.log(`Total: ${institutions.length} | Cached: ${cached} | Todo: ${todo.length}`);
  console.log(`This run: up to ${runCount} requests at ${DELAY_MS}ms (~${Math.round(runCount * DELAY_MS / 60000)} min)\n`);

  let queued = 0, geocoded = 0, failed = 0;

  for (const inst of todo) {
    if (queued >= MAX_REQUESTS) break;
    queued++;

    const query = buildQuery(inst);
    const result = await search(query);

    if (result) {
      cache[inst.key] = { lat: result.lat, lng: result.lng };
      geocoded++;
      if (geocoded % 20 === 0) saveCache();
      console.log(`[OK] ${inst.name} → ${result.lat.toFixed(5)}, ${result.lng.toFixed(5)}`);
    } else {
      cache[inst.key] = null;
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
