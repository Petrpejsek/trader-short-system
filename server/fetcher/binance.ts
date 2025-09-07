import config from '../../config/fetcher.json'
import deciderCfg from '../../config/decider.json'
import signalsCfg from '../../config/signals.json'
import type { MarketRawSnapshot, Kline, ExchangeFilters, UniverseItem } from '../../types/market_raw'
import { calcSpreadBps, clampSnapshotSize, toNumber, toUtcIso } from '../../services/fetcher/normalize'
import { request } from 'undici'
import { noteApiCall } from '../lib/rateLimits'
// TTL cache disabled by policy: no caching
import { request as undiciRequest } from 'undici'

const BASE_URL = 'https://fapi.binance.com'

type RetryConfig = {
  maxAttempts: number
  baseDelayMs: number
  maxDelayMs: number
}

async function sleep(ms: number): Promise<void> { return new Promise(res => setTimeout(res, ms)) }

async function withRetry<T>(fn: () => Promise<T>, retryCfg: RetryConfig): Promise<T> {
  let attempt = 0
  let lastError: any
  while (attempt < retryCfg.maxAttempts) {
    try { return await fn() } catch (e) { lastError = e; attempt += 1; if (attempt >= retryCfg.maxAttempts) break; const delay = Math.min(retryCfg.baseDelayMs * Math.pow(2, attempt - 1), retryCfg.maxDelayMs); await sleep(delay) }
  }
  throw lastError
}

async function httpGet(path: string, params?: Record<string, string | number>): Promise<any> {
  const qs = params ? new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)])).toString() : ''
  const url = `${BASE_URL}${path}${qs ? `?${qs}` : ''}`
  const ac = new AbortController()
  const to = setTimeout(() => ac.abort(), config.timeoutMs ?? 6000)
  try {
    const { body, statusCode, headers } = await request(url, { method: 'GET', signal: ac.signal })
    try { noteApiCall({ method: 'GET', path, status: Number(statusCode), headers }) } catch {}
    if (statusCode < 200 || statusCode >= 300) {
      try { noteApiCall({ method: 'GET', path, status: Number(statusCode), headers }) } catch {}
      throw new Error(`HTTP ${statusCode} ${path}`)
    }
    const text = await body.text()
    return JSON.parse(text)
  } finally {
    clearTimeout(to)
  }
}

async function httpGetCached(path: string, params: Record<string, string | number> | undefined, _ttlMs: number, _fresh = false): Promise<any> {
  // Strict NO-CACHE: always hit origin
  return httpGet(path, params)
}

async function getServerTime(): Promise<number> {
  const data = await withRetry(() => httpGet('/fapi/v1/time'), config.retry)
  const serverTime = toNumber(data?.serverTime)
  if (!serverTime) throw new Error('Invalid serverTime')
  return serverTime
}

type ExchangeInfoSymbol = {
  symbol: string
  filters: Array<{ filterType: string; tickSize?: string; stepSize?: string; minQty?: string; notional?: string; minNotional?: string }>
  status: string
  contractType?: string
  quoteAsset?: string
}

async function getExchangeInfo(): Promise<ExchangeFilters> {
  // Always fetch fresh exchangeInfo to avoid any caching
  const data = await withRetry(() => httpGet('/fapi/v1/exchangeInfo', undefined), config.retry)
  const symbols: ExchangeInfoSymbol[] = Array.isArray(data?.symbols) ? data.symbols : []
  const filters: ExchangeFilters = {}
  for (const s of symbols) {
    if (s.status !== 'TRADING') continue
    if (s.contractType && s.contractType !== 'PERPETUAL') continue
    if (s.quoteAsset && s.quoteAsset !== 'USDT') continue
    const priceFilter = s.filters.find(f => f.filterType === 'PRICE_FILTER')
    const lotSize = s.filters.find(f => f.filterType === 'LOT_SIZE')
    const minNotional = s.filters.find(f => f.filterType === 'MIN_NOTIONAL')
    const tickSize = toNumber(priceFilter?.tickSize)
    const stepSize = toNumber(lotSize?.stepSize)
    const minQty = toNumber(lotSize?.minQty)
    const minNot = toNumber((minNotional?.notional ?? minNotional?.minNotional) as any)
    if (!tickSize || !stepSize || !minQty || !minNot) continue
    filters[s.symbol] = { tickSize, stepSize, minQty, minNotional: minNot }
  }
  return filters
}

async function getTopNUsdtSymbols(n: number, fresh = false): Promise<string[]> {
  const data = await withRetry(() => httpGetCached('/fapi/v1/ticker/24hr', undefined, (config as any).cache?.ticker24hMs ?? 30000, fresh), config.retry)
  const entries = Array.isArray(data) ? data : []
  const filtered = entries.filter((e: any) => e?.symbol?.endsWith('USDT'))
  const sorted = filtered.sort((a: any, b: any) => {
    const va = Number(a.quoteVolume)
    const vb = Number(b.quoteVolume)
    if (vb !== va) return vb - va
    return String(a.symbol).localeCompare(String(b.symbol))
  })
  const unique = Array.from(new Set(sorted.map((e: any) => e.symbol)))
  return unique.slice(0, n)
}

async function getTopGainersUsdtSymbols(n: number, fresh = false): Promise<string[]> {
  const data = await withRetry(() => httpGetCached('/fapi/v1/ticker/24hr', undefined, (config as any).cache?.ticker24hMs ?? 30000, fresh), config.retry)
  const entries = Array.isArray(data) ? data : []
  const filtered = entries.filter((e: any) => e?.symbol?.endsWith('USDT'))
  const sorted = filtered.sort((a: any, b: any) => {
    const pa = Number(a.priceChangePercent)
    const pb = Number(b.priceChangePercent)
    if (pb !== pa) return pb - pa
    // tie-break by volume
    const va = Number(a.quoteVolume)
    const vb = Number(b.quoteVolume)
    if (vb !== va) return vb - va
    return String(a.symbol).localeCompare(String(b.symbol))
  })
  const unique = Array.from(new Set(sorted.map((e: any) => e.symbol)))
  return unique.slice(0, n)
}

async function getKlines(symbol: string, interval: string, limit: number, fresh = false): Promise<Kline[]> {
  const run = () => httpGet('/fapi/v1/klines', { symbol, interval, limit })
  let raw: any
  try {
    raw = await withRetry(run, config.retry)
  } catch (e) {
    if (interval === '1h') {
      const jitter = 200 + Math.floor(Math.random() * 200)
      await sleep(jitter)
      raw = await withRetry(run, { ...config.retry, maxAttempts: 1 })
    } else {
      throw e
    }
  }
  if (!Array.isArray(raw)) return []
  return raw.map((k: any) => ({
    openTime: toUtcIso(k[0])!, open: toNumber(k[1])!, high: toNumber(k[2])!, low: toNumber(k[3])!, close: toNumber(k[4])!, volume: toNumber(k[5])!, closeTime: toUtcIso(k[6])!
  })).filter(k => Number.isFinite(k.open) && Number.isFinite(k.close))
}

async function getFundingRate(symbol: string): Promise<number | undefined> {
  const data = await withRetry(() => httpGet('/fapi/v1/fundingRate', { symbol, limit: 1 }), config.retry)
  if (!Array.isArray(data) || data.length === 0) return undefined
  return toNumber(data[0]?.fundingRate)
}

async function getOpenInterestNow(symbol: string): Promise<number | undefined> {
  const data = await withRetry(() => httpGet('/fapi/v1/openInterest', { symbol }), config.retry)
  return toNumber(data?.openInterest)
}

async function getOpenInterestHistChange1h(symbol: string): Promise<number | undefined> {
  // Use 5m OI history to compute ~1h change
  try {
    const data = await withRetry(() => httpGet('/futures/data/openInterestHist', { symbol, period: '5m', limit: 13 }), { ...config.retry, maxAttempts: 2 })
    if (!Array.isArray(data) || data.length < 2) return undefined
    const first = toNumber(data[0]?.sumOpenInterest) || 0
    const last = toNumber(data[data.length - 1]?.sumOpenInterest) || 0
    if (first <= 0 || last <= 0) return undefined
    return ((last - first) / first) * 100
  } catch {
    return undefined
  }
}

async function getBookTicker(symbol: string): Promise<{ bid: number | undefined; ask: number | undefined }> {
  try {
    const d = await withRetry(() => httpGet('/fapi/v1/ticker/bookTicker', { symbol }), config.retry)
    return { bid: toNumber(d?.bidPrice), ask: toNumber(d?.askPrice) }
  } catch { return { bid: undefined, ask: undefined } }
}

async function getOrderBook(symbol: string, limit: number): Promise<{ bids: Array<[number, number]>; asks: Array<[number, number]> } | undefined> {
  try {
    const d = await withRetry(() => httpGet('/fapi/v1/depth', { symbol, limit }), config.retry)
    const toArr = (a: any[]) => Array.isArray(a) ? a.map((x: any) => [toNumber(x[0]) || 0, toNumber(x[1]) || 0] as [number, number]).filter(x => x[0] > 0 && x[1] > 0) : []
    return { bids: toArr(d?.bids || []), asks: toArr(d?.asks || []) }
  } catch { return undefined }
}

function calcDepthWithinPctUSD(
  bids: Array<[number, number]>,
  asks: Array<[number, number]>,
  markPrice: number,
  pct: number
): { bids: number; asks: number } | undefined {
  if (!Array.isArray(bids) || !Array.isArray(asks) || !markPrice || markPrice <= 0) return undefined
  const lower = markPrice * (1 - pct)
  const upper = markPrice * (1 + pct)
  let bidUsd = 0
  for (const [price, qty] of bids) {
    if (price < lower) break
    bidUsd += price * qty
  }
  let askUsd = 0
  for (const [price, qty] of asks) {
    if (price > upper) break
    askUsd += price * qty
  }
  if (!Number.isFinite(bidUsd) || !Number.isFinite(askUsd)) return undefined
  return { bids: bidUsd, asks: askUsd }
}

function ema(values: number[], p: number): number | null {
  if (!Array.isArray(values) || values.length === 0) return null
  // Seeded EMA so that we return a value even when length < period
  const k = 2 / (p + 1)
  let e = values[0]
  for (let i = 1; i < values.length; i++) e = values[i] * k + e * (1 - k)
  return Number.isFinite(e) ? e : null
}

function rsi(values: number[], period = 14): number | null {
  if (values.length <= period) return null
  let gains = 0
  let losses = 0
  for (let i = 1; i <= period; i++) {
    const diff = values[i] - values[i - 1]
    if (diff >= 0) gains += diff; else losses -= diff
  }
  let avgGain = gains / period
  let avgLoss = losses / period
  for (let i = period + 1; i < values.length; i++) {
    const diff = values[i] - values[i - 1]
    const gain = diff > 0 ? diff : 0
    const loss = diff < 0 ? -diff : 0
    avgGain = (avgGain * (period - 1) + gain) / period
    avgLoss = (avgLoss * (period - 1) + loss) / period
  }
  if (avgLoss === 0) return 100
  const rs = avgGain / avgLoss
  return 100 - 100 / (1 + rs)
}

function atrPct(klines: Kline[]): number | null {
  if (!klines?.length || klines.length < 15) return null
  const highs = klines.map(k => k.high), lows = klines.map(k => k.low), closes = klines.map(k => k.close)
  const tr: number[] = []
  for (let i = 1; i < highs.length; i++) {
    const hl = highs[i] - lows[i]
    const hc = Math.abs(highs[i] - closes[i - 1])
    const lc = Math.abs(lows[i] - closes[i - 1])
    tr.push(Math.max(hl, hc, lc))
  }
  let atr = tr.slice(0, 14).reduce((a, b) => a + b, 0) / 14
  for (let i = 14; i < tr.length; i++) atr = (atr * 13 + tr[i]) / 14
  const lastClose = closes[closes.length - 1]
  return lastClose ? (atr / lastClose) * 100 : null
}

function computeDailyVwapFromM15(m15: Kline[]): { vwap: number | null; rel: number | null } {
  if (!Array.isArray(m15) || m15.length === 0) return { vwap: null, rel: null }
  const now = new Date()
  const y = now.getUTCFullYear(), m = now.getUTCMonth(), d = now.getUTCDate()
  const start = Date.UTC(y, m, d, 0, 0, 0)
  let pv = 0, vv = 0, lastClose: number | null = null
  for (const k of m15) {
    const ts = Date.parse(k.openTime)
    if (ts < start) continue
    const tp = (k.high + k.low + k.close) / 3
    pv += tp * k.volume
    vv += k.volume
    lastClose = k.close
  }
  if (vv <= 0 || lastClose == null) return { vwap: null, rel: null }
  const vwap = pv / vv
  const rel = (lastClose - vwap) / vwap
  return { vwap, rel }
}

function computeSRLevels(h1: Kline[], maxLevels = 4): { support: number[]; resistance: number[] } {
  const support: number[] = []
  const resistance: number[] = []
  if (!Array.isArray(h1) || h1.length < 20) return { support, resistance }
  const window = 3
  for (let i = window; i < h1.length - window; i++) {
    const isLow = h1.slice(i - window, i + window + 1).every((k, idx) => idx === window || k.low >= h1[i].low)
    const isHigh = h1.slice(i - window, i + window + 1).every((k, idx) => idx === window || k.high <= h1[i].high)
    if (isLow) support.push(h1[i].low)
    if (isHigh) resistance.push(h1[i].high)
  }
  // sort and pick nearest 2 levels around last close
  const lastClose = h1[h1.length - 1].close
  const sortByDist = (arr: number[], dir: 'below' | 'above') => arr
    .filter(v => (dir === 'below' ? v <= lastClose : v >= lastClose))
    .sort((a, b) => Math.abs(a - lastClose) - Math.abs(b - lastClose))
    .slice(0, Math.max(2, Math.floor(maxLevels / 2)))
  return { support: sortByDist(support, 'below'), resistance: sortByDist(resistance, 'above') }
}

async function runWithConcurrency<T>(factories: Array<() => Promise<T>>, limit: number): Promise<Array<{ ok: true; value: T } | { ok: false; error: any }>> {
  const results: Array<{ ok: true; value: T } | { ok: false; error: any }> = []
  let idx = 0
  const inFlight: Promise<void>[] = []
  async function runOne(factory: () => Promise<T>) {
    try { const value = await factory(); results.push({ ok: true, value }) } catch (error) { results.push({ ok: false, error }) }
  }
  while (idx < factories.length || inFlight.length > 0) {
    while (idx < factories.length && inFlight.length < limit) {
      const p = runOne(factories[idx++])
      inFlight.push(p)
      p.finally(() => { const i = inFlight.indexOf(p); if (i >= 0) inFlight.splice(i, 1) })
    }
    if (inFlight.length > 0) await Promise.race(inFlight)
  }
  return results
}

// Simple mapLimit helper
async function mapLimit<T, R>(arr: T[], limit: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const results: R[] = []
  let index = 0
  const workers = Array(Math.min(limit, arr.length)).fill(0).map(async () => {
    while (true) {
      const i = index++
      if (i >= arr.length) break
      results[i] = await fn(arr[i])
    }
  })
  await Promise.all(workers)
  return results
}

// REST-only builder – no WS cache access

export async function buildMarketRawSnapshot(opts?: { universeStrategy?: 'volume'|'gainers'; desiredTopN?: number; includeSymbols?: string[]; fresh?: boolean; allowPartial?: boolean }): Promise<MarketRawSnapshot> {
  const t0 = Date.now()
  const globalAc = new AbortController()
  const globalTimeout = setTimeout(() => globalAc.abort(), (config as any).globalDeadlineMs ?? 8000)
  const uniKlines: Record<string, { H1?: Kline[]; M15?: Kline[]; H4?: Kline[] }> = {}
  const exchangeFilters = await getExchangeInfo()
  const filteredSymbols = Object.keys(exchangeFilters)
  // Fixed target: always BTC+ETH + exactly N-2 alts (when possible)
  const desired = Number.isFinite(opts?.desiredTopN as any) && (opts!.desiredTopN as any) > 0 ? (opts!.desiredTopN as number) : config.universe.topN
  const altTarget = Math.max(0, desired - 2)
  // When includeSymbols provided, expand target to accommodate them
  const hasIncludeSymbols = Array.isArray(opts?.includeSymbols) && opts!.includeSymbols!.length > 0
  const effectiveAltTarget = hasIncludeSymbols ? Math.max(altTarget, altTarget + opts!.includeSymbols!.length) : altTarget
  // Pull a large candidate pool (24h tickers) a připrav SHORT mix (losers + overextended)
  const strategy = (opts?.universeStrategy || (config as any)?.universe?.strategy || 'volume') as 'volume'|'gainers'
  const fresh = Boolean(opts?.fresh)
  const tickRaw = await withRetry(() => httpGet('/fapi/v1/ticker/24hr'), config.retry)
  const tickEntries: Array<{ symbol: string; quoteVolume?: number; priceChangePercent?: number }> = Array.isArray(tickRaw) ? tickRaw.filter((e: any) => e?.symbol?.endsWith('USDT')) : []
  const tickFiltered = tickEntries.filter((e: any) => filteredSymbols.includes(String(e.symbol)))
  // losers: priceChangePercent < 0 (nejvíce ztrácející)
  const losers = [...tickFiltered]
    .filter(e => Number(e.priceChangePercent) < 0)
    .sort((a, b) => Number(a.priceChangePercent) - Number(b.priceChangePercent))
    .map(e => e.symbol)
  // overextended: priceChangePercent > 0 (největší gainers) – pro fade
  const gainers = [...tickFiltered]
    .filter(e => Number(e.priceChangePercent) > 0)
    .sort((a, b) => Number(b.priceChangePercent) - Number(a.priceChangePercent))
    .map(e => e.symbol)
  // Vyluč BTC/ETH z alt seznamu
  const losersAlts = losers.filter(s => s !== 'BTCUSDT' && s !== 'ETHUSDT')
  const gainersAlts = gainers.filter(s => s !== 'BTCUSDT' && s !== 'ETHUSDT')
  // Cíl: altTarget = desired - 2 (BTC/ETH). Mix: až 35 losers + až 15 overextended, zbytek oříznout na altTarget.
  const losersWanted = Math.min(35, Math.max(0, effectiveAltTarget))
  const overWanted = Math.min(15, Math.max(0, effectiveAltTarget - losersWanted))
  const mixed = losersAlts.slice(0, losersWanted).concat(gainersAlts.slice(0, overWanted))
  // includeSymbols mají přednost (pokud jsou platné USDT a na futures)
  // Normalize includeSymbols and force them to the front of the alt list (if supported on futures USDT)
  const includeNorm = Array.from(new Set(((opts?.includeSymbols || []) as string[])
    .map(s => String(s || '').toUpperCase().replace('/', ''))
    .map(s => s.endsWith('USDT') ? s : `${s}USDT`)
    .filter(s => s !== 'BTCUSDT' && s !== 'ETHUSDT' && filteredSymbols.includes(s))))
  // Merge include first, then mixed list without duplicates
  const mergedPref = includeNorm.concat(mixed.filter(s => !includeNorm.includes(s)))
  // Build universe symbol list (alts only)
  const altSymbols: string[] = mergedPref.slice(0, effectiveAltTarget)
  const universeSymbols = altSymbols.slice()

  // Fetch klines via REST for BTC/ETH and alts
  let backfillCount = 0
  let dropsAlts: string[] = []

  const klinesTasks: Array<() => Promise<any>> = []
  const coreIntervals: Array<{ key: 'H4'|'H1'|'M15'; interval: string; limit: number }> = [
    { key: 'H4', interval: '4h', limit: (config as any).candles || 220 },
    { key: 'H1', interval: '1h', limit: (config as any).candles || 220 },
    { key: 'M15', interval: '15m', limit: (config as any).candles || 220 }
  ]
  for (const c of coreIntervals) klinesTasks.push(async () => ({ key: `btc.${c.key}`, k: await getKlines('BTCUSDT', c.interval, c.limit) }))
  for (const c of coreIntervals) klinesTasks.push(async () => ({ key: `eth.${c.key}`, k: await getKlines('ETHUSDT', c.interval, c.limit) }))
  // Lighter alt intervals to keep snapshot under maxSnapshotBytes
  const altH1Limit = Number((config as any)?.altH1Limit ?? 80)
  const altM15Limit = Number((config as any)?.altM15Limit ?? 96)
  const altIntervals: Array<{ key: 'H1'|'M15'; interval: string; limit: number }> = [
    { key: 'H1', interval: '1h', limit: altH1Limit },
    { key: 'M15', interval: '15m', limit: altM15Limit }
  ]
  for (const sym of universeSymbols) {
    for (const c of altIntervals) {
      klinesTasks.push(async () => {
        const k = await getKlines(sym, c.interval, c.limit)
        uniKlines[sym] = uniKlines[sym] || {}
        ;(uniKlines[sym] as any)[c.key] = k
        return { key: `${sym}.${c.key}`, k }
      })
    }
  }
  const klinesSettled = await runWithConcurrency(klinesTasks, config.concurrency)
  const btc: any = { klines: {} }, eth: any = { klines: {} }
  for (const s of klinesSettled) {
    if ((s as any).ok) {
      const r = (s as any).value
      const [left, right] = r.key.split('.')
      if (left === 'btc') (btc.klines as any)[right] = r.k
      else if (left === 'eth') (eth.klines as any)[right] = r.k
      else { const sym = left; if (!uniKlines[sym]) uniKlines[sym] = {}; (uniKlines[sym] as any)[right] = r.k }
    }
  }

  // Funding & OI now
  const fundingMap: Record<string, number | undefined> = {}
  const oiNowMap: Record<string, number | undefined> = {}
  const oiChangeMap: Record<string, number | undefined> = {}
  const coreSymbols = ['BTCUSDT', 'ETHUSDT']

  // Cold-start guard: pokud ještě nemáme H1 data pro významnou část altů,
  // omezíme side-dotazy (funding/OI/oiChg) jen na BTC/ETH, aby první volání bylo rychlé a stabilní.
  const altH1ReadyCount = universeSymbols.reduce((acc, s) => {
    const h1 = (uniKlines[s]?.H1 || []) as Kline[]
    return acc + (Array.isArray(h1) && h1.length > 0 ? 1 : 0)
  }, 0)
  const coldStart = altH1ReadyCount < Math.max(8, Math.floor(universeSymbols.length * 0.25))

  const fundingSymbolsBase = (config as any).fundingMode === 'coreOnly' ? coreSymbols : universeSymbols.concat(coreSymbols)
  const oiSymbolsBase = (config as any).openInterestMode === 'coreOnly' ? coreSymbols : universeSymbols.concat(coreSymbols)

  const fundingSymbols = coldStart ? coreSymbols : fundingSymbolsBase
  const oiSymbols = coldStart ? coreSymbols : oiSymbolsBase

  const sideTasks: Array<() => Promise<any>> = []
  for (const s of fundingSymbols) { sideTasks.push(() => getFundingRate(s).then(v => ({ type: 'fund', s, v }))) }
  for (const s of oiSymbols) { sideTasks.push(() => getOpenInterestNow(s).then(v => ({ type: 'oi', s, v }))) }
  // OI hist change 1h – na cold start pouze pro core, jinak pro celý výběr
  const oiHistSymbols = coldStart ? coreSymbols : oiSymbols
  for (const s of oiHistSymbols) { sideTasks.push(() => getOpenInterestHistChange1h(s).then(v => ({ type: 'oiChg', s, v }))) }

  const sideSettled = await runWithConcurrency(sideTasks, config.concurrency)
  for (const r of sideSettled) {
    if ((r as any).ok) {
      const v = (r as any).value
      if (v.type === 'fund') fundingMap[v.s] = v.v
      if (v.type === 'oi') oiNowMap[v.s] = v.v
      if (v.type === 'oiChg') oiChangeMap[v.s] = v.v
    }
  }

  const latencyMs = Date.now() - t0

  const tickerMap = await (async () => {
    const raw = await withRetry(() => httpGet('/fapi/v1/ticker/24hr', undefined), config.retry)
    const out: Record<string, { volume24h_usd?: number; lastPrice?: number; closeTimeMs?: number; priceChange?: number; priceChangePercent?: number; volume?: number }> = {}
    for (const t of raw) {
      const sym = t?.symbol
      if (!sym || !sym.endsWith('USDT')) continue
      out[sym] = { 
        volume24h_usd: toNumber(t?.quoteVolume), 
        lastPrice: toNumber(t?.lastPrice), 
        closeTimeMs: toNumber(t?.closeTime),
        priceChange: toNumber(t?.priceChange),
        priceChangePercent: toNumber(t?.priceChangePercent),
        volume: toNumber(t?.volume)
      }
    }
    return out
  })()

  const universe: UniverseItem[] = []
  const warnings: string[] = []
  const hasCore = (sym: 'BTCUSDT'|'ETHUSDT') => {
    const core = sym === 'BTCUSDT' ? (btc.klines as any) : (eth.klines as any)
    return !!(core?.H1 && core?.H4 && core?.M15 && core.H1.length && core.H4.length && core.M15.length)
  }
  const hasAlt = (sym: string) => Array.isArray(uniKlines[sym]?.H1) && (uniKlines[sym] as any).H1.length > 0
  for (const sym of ['BTCUSDT', 'ETHUSDT']) {
    const core = sym === 'BTCUSDT' ? (btc.klines as any) : (eth.klines as any)
    const coreOkNow = !!(core?.H1 && core?.H4 && core.H1.length && core.H4.length)
    if (!coreOkNow) { warnings.push(`drop:core:no_klines:${sym}`); continue }
    const item: UniverseItem = { symbol: sym, klines: { H1: core?.H1, M15: core?.M15, H4: core?.H4 }, funding: fundingMap[sym], oi_now: oiNowMap[sym], oi_hist: [], depth1pct_usd: undefined, spread_bps: undefined, volume24h_usd: tickerMap[sym]?.volume24h_usd, price: tickerMap[sym]?.lastPrice, exchange: 'Binance', market_type: 'perp', fees_bps: null, tick_size: (exchangeFilters as any)?.[sym]?.tickSize ?? null }
    // Analytics
    const h1 = item.klines.H1 || []
    const m15 = item.klines.M15 || []
    const closeH1 = h1.map(k => k.close)
    const closeM15 = m15.map(k => k.close)
    item.atr_pct_H1 = atrPct(h1)
    item.atr_pct_M15 = atrPct(m15)
    item.atr_h1 = item.atr_pct_H1 != null && h1.length ? (item.atr_pct_H1 / 100) * h1[h1.length - 1].close : null
    item.atr_m15 = item.atr_pct_M15 != null && m15.length ? (item.atr_pct_M15 / 100) * m15[m15.length - 1].close : null
    item.ema20_H1 = ema(closeH1, 20)
    item.ema50_H1 = ema(closeH1, 50)
    item.ema200_H1 = ema(closeH1, 200)
    item.ema20_M15 = ema(closeM15, 20)
    item.ema50_M15 = ema(closeM15, 50)
    item.ema200_M15 = ema(closeM15, 200)
    item.ema_h1 = { 20: item.ema20_H1, 50: item.ema50_H1, 200: item.ema200_H1 }
    item.ema_m15 = { 20: item.ema20_M15, 50: item.ema50_M15, 200: item.ema200_M15 }
    item.rsi_H1 = rsi(closeH1, 14)
    item.rsi_M15 = rsi(closeM15, 14)
    item.oi_change_1h_pct = oiChangeMap[sym]
    item.funding_8h_pct = Number.isFinite(item.funding as any) ? (item.funding as any) * 100 : null
    const vwap = computeDailyVwapFromM15(m15)
    item.vwap_daily = vwap.vwap
    item.vwap_rel_daily = vwap.rel
    item.vwap_today = vwap.vwap
    item.vwap_rel_today = vwap.rel
    const sr = computeSRLevels(h1)
    item.support = sr.support
    item.resistance = sr.resistance
    // Gap/context
    item.prev_day_close = (() => {
      if (!m15.length) return null
      const last = m15[m15.length - 1]
      const d = new Date(last.openTime)
      d.setUTCDate(d.getUTCDate() - 1); d.setUTCHours(23, 59, 59, 999)
      // STRICT: No fallbacks allowed - return null if insufficient data
      return null
    })()
    item.h4_high = Array.isArray((btc as any)?.klines?.H4) ? Math.max(...((btc as any).klines.H4 as Kline[]).map(k=>k.high)) : null
    item.h4_low = Array.isArray((btc as any)?.klines?.H4) ? Math.min(...((btc as any).klines.H4 as Kline[]).map(k=>k.low)) : null
    item.d1_high = null
    item.d1_low = null
    // Propagate computed indicators and market fields back to core btc/eth
    const coreTarget = (sym === 'BTCUSDT') ? (btc as any) : (eth as any)
    coreTarget.funding = item.funding
    coreTarget.oi_now = item.oi_now
    coreTarget.oi_change_1h_pct = item.oi_change_1h_pct
    coreTarget.funding_8h_pct = item.funding_8h_pct
    coreTarget.atr_pct_H1 = item.atr_pct_H1
    coreTarget.atr_pct_M15 = item.atr_pct_M15
    coreTarget.atr_h1 = item.atr_h1
    coreTarget.atr_m15 = item.atr_m15
    coreTarget.ema20_H1 = item.ema20_H1
    coreTarget.ema50_H1 = item.ema50_H1
    coreTarget.ema200_H1 = item.ema200_H1
    coreTarget.ema20_M15 = item.ema20_M15
    coreTarget.ema50_M15 = item.ema50_M15
    coreTarget.ema200_M15 = item.ema200_M15
    coreTarget.rsi_H1 = item.rsi_H1
    coreTarget.rsi_M15 = item.rsi_M15
    coreTarget.vwap_today = item.vwap_today
    coreTarget.vwap_daily = item.vwap_daily
    coreTarget.vwap_rel_today = item.vwap_rel_today
    coreTarget.vwap_rel_daily = item.vwap_rel_daily
    coreTarget.volume24h_usd = item.volume24h_usd
    coreTarget.price = item.price
    coreTarget.support = item.support
    coreTarget.resistance = item.resistance
  }
  for (const sym of universeSymbols) {
    if (!hasAlt(sym) && !(opts as any)?.allowPartial) { warnings.push(`drop:alt:noH1:${sym}`); continue }
    const item: UniverseItem = { symbol: sym, klines: { H1: (uniKlines[sym]?.H1 || []), M15: (uniKlines[sym]?.M15 || []) }, funding: fundingMap[sym], oi_now: oiNowMap[sym], oi_hist: [], depth1pct_usd: undefined, spread_bps: undefined, volume24h_usd: tickerMap[sym]?.volume24h_usd, price: tickerMap[sym]?.lastPrice, exchange: 'Binance', market_type: 'perp', fees_bps: null, tick_size: (exchangeFilters as any)?.[sym]?.tickSize ?? null }
    // Analytics for alts
    const h1 = item.klines.H1 || []
    const m15 = item.klines.M15 || []
    const closeH1 = h1.map(k => k.close)
    const closeM15 = m15.map(k => k.close)
    item.atr_pct_H1 = atrPct(h1)
    item.atr_pct_M15 = atrPct(m15)
    item.atr_h1 = item.atr_pct_H1 != null && h1.length ? (item.atr_pct_H1 / 100) * h1[h1.length - 1].close : null
    item.atr_m15 = item.atr_pct_M15 != null && m15.length ? (item.atr_pct_M15 / 100) * m15[m15.length - 1].close : null
    item.ema20_H1 = ema(closeH1, 20)
    item.ema50_H1 = ema(closeH1, 50)
    item.ema200_H1 = ema(closeH1, 200)
    item.ema20_M15 = ema(closeM15, 20)
    item.ema50_M15 = ema(closeM15, 50)
    item.ema200_M15 = ema(closeM15, 200)
    item.ema_h1 = { 20: item.ema20_H1, 50: item.ema50_H1, 200: item.ema200_H1 }
    item.ema_m15 = { 20: item.ema20_M15, 50: item.ema50_M15, 200: item.ema200_M15 }
    item.rsi_H1 = rsi(closeH1, 14)
    item.rsi_M15 = rsi(closeM15, 14)
    item.oi_change_1h_pct = oiChangeMap[sym]
    item.funding_8h_pct = Number.isFinite(item.funding as any) ? (item.funding as any) * 100 : null
    const vwap = computeDailyVwapFromM15(m15)
    item.vwap_daily = vwap.vwap
    item.vwap_rel_daily = vwap.rel
    item.vwap_today = vwap.vwap
    item.vwap_rel_today = vwap.rel
    const sr = computeSRLevels(h1)
    item.support = sr.support
    item.resistance = sr.resistance
    // Gap/context
    item.prev_day_close = (() => {
      if (!m15.length) return null
      const last = m15[m15.length - 1]
      const d = new Date(last.openTime)
      d.setUTCDate(d.getUTCDate() - 1); d.setUTCHours(23, 59, 59, 999)
      // STRICT: No H1 fallbacks allowed - return null if insufficient data
      return null
    })()
    item.h4_high = Array.isArray(h1) ? Math.max(...h1.map(k=>k.high)) : null
    item.h4_low = Array.isArray(h1) ? Math.min(...h1.map(k=>k.low)) : null
    item.d1_high = null
    item.d1_low = null
    universe.push(item)
  }
  // Enforce fixed size: require exactly 28 alts in the universe (unless includeSymbols override)
  if (universe.length !== altTarget && !hasIncludeSymbols) {
    if (!(opts as any)?.allowPartial) {
      const err: any = new Error('UNIVERSE_INCOMPLETE')
      err.stage = 'universe_incomplete'
      err.expected = altTarget
      err.actual = universe.length
      throw err
    }
  }

  const latestTimes: number[] = []
  const pushTime = (iso?: string) => { if (iso) latestTimes.push(Date.parse(iso)) }
  for (const arr of [btc.klines?.M15, eth.klines?.M15]) { const last = Array.isArray(arr) ? arr[arr.length - 1] : undefined; pushTime(last?.closeTime) }
  for (const sym of universe) { const last2 = sym.klines?.M15?.[sym.klines?.M15.length - 1]; pushTime(last2?.closeTime) }
  const feedsOk = latestTimes.every(t => (Date.now() - t) <= (config.staleThresholdSec * 1000))

  // Orderbook/Spread data (best-effort)
  try {
    if (String((config as any).depthMode || '').toLowerCase() !== 'none') {
      const obSymbols = universeSymbols.concat(coreSymbols)
      const tasks: Array<() => Promise<{ s: string; spread?: number; d05?: { bids: number; asks: number } | undefined; d1?: { bids: number; asks: number } | undefined }>> = []
      for (const s of obSymbols) {
        tasks.push(async () => {
          const [bt, ob] = await Promise.all([getBookTicker(s), getOrderBook(s, (config as any)?.orderbook?.limit || 50)])
          const spread = calcSpreadBps(bt.bid, bt.ask)
          const mid = (bt.bid && bt.ask) ? ((bt.bid + bt.ask) / 2) : (tickerMap[s]?.lastPrice || 0)
          const d05 = ob && mid ? calcDepthWithinPctUSD(ob.bids, ob.asks, mid, 0.005) : undefined
          const d1 = ob && mid ? calcDepthWithinPctUSD(ob.bids, ob.asks, mid, 0.01) : undefined
          return { s, spread, d05, d1 }
        })
      }
      const obSettled = await runWithConcurrency(tasks, Math.min(8, (config as any).concurrency || 8))
      for (const r of obSettled) {
        if ((r as any).ok) {
          const { s, spread, d05, d1 } = (r as any).value
          const target = s === 'BTCUSDT' ? (btc as any) : s === 'ETHUSDT' ? (eth as any) : (universe.find(u => u.symbol === s) as any)
          if (target) {
            if (spread != null) target.spread_bps = spread
            if (d05) target.liquidity_usd_0_5pct = d05
            if (d1) target.liquidity_usd_1pct = d1
            const bidsUsd = (d05?.bids ?? 0) + (d1?.bids ?? 0)
            const asksUsd = (d05?.asks ?? 0) + (d1?.asks ?? 0)
            if ((bidsUsd + asksUsd) > 0) target.liquidity_usd = bidsUsd + asksUsd
          }
        }
      }
    }
  } catch {}

  // BTC/ETH regime filter + ticker data
  try {
    const regimeFor = (set: any) => {
      const h1 = Array.isArray(set?.klines?.H1) ? set.klines.H1 as Kline[] : []
      const m15 = Array.isArray(set?.klines?.M15) ? set.klines.M15 as Kline[] : []
      const h1c = h1.length ? h1[h1.length - 1].close : null
      const h1p = h1.length > 1 ? h1[h1.length - 2].close : null
      const m15c = m15.length ? m15[m15.length - 1].close : null
      const pct = (h1c != null && h1p != null) ? ((h1c / h1p) - 1) * 100 : null
      return { h1_close: h1c ?? null, m15_close: m15c ?? null, pct_change_1h: pct ?? null }
    }
    ;(btc as any).regime = regimeFor(btc)
    ;(eth as any).regime = regimeFor(eth)
    
    // Add ticker data to BTC/ETH objects
    const btcTicker = tickerMap['BTCUSDT']
    const ethTicker = tickerMap['ETHUSDT']
    
    if (btcTicker) {
      ;(btc as any).price = btcTicker.lastPrice
      ;(btc as any).volume24h_usd = btcTicker.volume24h_usd
      ;(btc as any).volume24h_btc = btcTicker.volume
      ;(btc as any).priceChange = btcTicker.priceChange
      ;(btc as any).priceChangePercent = btcTicker.priceChangePercent
    }
    
    if (ethTicker) {
      ;(eth as any).price = ethTicker.lastPrice
      ;(eth as any).volume24h_usd = ethTicker.volume24h_usd
      ;(eth as any).volume24h_eth = ethTicker.volume
      ;(eth as any).priceChange = ethTicker.priceChange
      ;(eth as any).priceChangePercent = ethTicker.priceChangePercent
    }
  } catch {}

  // Policy
  const policy = {
    max_hold_minutes: Number((signalsCfg as any)?.expires_in_min ?? null) || undefined,
    risk_per_trade_pct: (signalsCfg as any)?.risk_pct_by_posture || undefined,
    risk_per_trade_pct_flat: Number((signalsCfg as any)?.risk_pct ?? null) || undefined,
    max_leverage: Number((deciderCfg as any)?.final_picker?.max_leverage ?? null) || undefined
  }

  const snapshot: MarketRawSnapshot = {
    timestamp: new Date().toISOString(),
    latency_ms: latencyMs,
    feeds_ok: feedsOk,
    data_warnings: warnings,
    btc, eth, universe, exchange_filters: exchangeFilters,
    policy,
    exchange: 'Binance',
    market_type: 'perp',
    regime: {
      BTCUSDT: { h1_change_pct: (()=>{ try { const h1 = (btc as any)?.klines?.H1 as Kline[]; return (h1?.length>1 && Number.isFinite(h1[h1.length-2]?.close) && Number.isFinite(h1[h1.length-1]?.close)) ? (((h1[h1.length-1].close / h1[h1.length-2].close) - 1) * 100) : null } catch { return null } })() },
      ETHUSDT: { h1_change_pct: (()=>{ try { const h1 = (eth as any)?.klines?.H1 as Kline[]; return (h1?.length>1 && Number.isFinite(h1[h1.length-2]?.close) && Number.isFinite(h1[h1.length-1]?.close)) ? (((h1[h1.length-1].close / h1[h1.length-2].close) - 1) * 100) : null } catch { return null } })() }
    }
  }
  ;(globalThis as any).__perf_last_snapshot = {
    drops_noH1: dropsAlts.length ? dropsAlts : warnings.filter(w => w.startsWith('drop:alt:noH1:')).map(w => w.split(':').pop() as string),
    lastBackfillCount: backfillCount,
    includedSymbolsCount: 2 + universe.length
  }
  const json = JSON.stringify(snapshot)
  if (!clampSnapshotSize(json, config.maxSnapshotBytes)) throw new Error('Snapshot too large')
  clearTimeout(globalTimeout)
  return snapshot
}


