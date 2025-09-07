import WebSocket from 'ws'
import { fetch } from 'undici'
import { getBinanceAPI } from '../../trading/binance_futures'

export type AuditFn = (evt: { type: 'cancel' | 'filled'; symbol: string; orderId?: number; side?: string | null; otype?: string | null; source: 'binance_ws'; reason?: string | null; payload?: any }) => void

interface StartOpts {
  audit: AuditFn
  apiKey?: string
  keepaliveMinutes?: number
}

// Module-level state (available to helpers)
const positions: Map<string, { symbol: string; positionAmt: number; entryPrice: number | null; positionSide: 'LONG'|'SHORT'|null; leverage: number | null; updatedAt: number }>
  = new Map()
const openOrdersById: Map<number, any> = new Map()
let hadAccountUpdate = false
let hadOrderUpdate = false

// Helper function to identify internal vs external orders
function isInternalClientId(id: string | null | undefined): boolean {
  const ns = String(process.env.CLIENT_ID_NS || 'short_real')
  const s = String(id || '')
  return (
    s.startsWith(`e_l_${ns}_`) ||
    s.startsWith(`x_sl_${ns}_`) ||
    s.startsWith(`x_tp_tm_${ns}_`) ||
    s.startsWith(`x_tp_l_${ns}_`)
  )
}

export function startBinanceUserDataWs(opts: StartOpts): void {
  const apiKey = opts.apiKey || process.env.BINANCE_API_KEY || ''
  if (!apiKey || apiKey.includes('mock')) return // no real keys, skip
  try { console.info('[USERDATA_WS_START]') } catch {}
  const keepaliveMs = Math.max(1, opts.keepaliveMinutes ?? 30) * 60 * 1000
  let listenKey: string | null = null
  let ws: WebSocket | null = null
  let refreshTimer: NodeJS.Timeout | null = null

  async function rehydratePositionsOnce(): Promise<void> {
    try {
      const api = getBinanceAPI() as any
      const list = await api.getPositions()
      const now = Date.now()
      if (Array.isArray(list)) {
        for (const p of list) {
          try {
            const sym = String(p?.symbol || '')
            if (!sym) continue
            const pa = Number(p?.positionAmt)
            const ep = Number(p?.entryPrice)
            const psdRaw = String(p?.positionSide || '')
            const psd = psdRaw === 'LONG' ? 'LONG' : psdRaw === 'SHORT' ? 'SHORT' : (Number.isFinite(pa) ? (pa < 0 ? 'SHORT' : 'LONG') : null)
            const lev = Number(p?.leverage)
            positions.set(sym, {
              symbol: sym,
              positionAmt: Number.isFinite(pa) ? pa : 0,
              entryPrice: Number.isFinite(ep) ? ep : null,
              positionSide: psd,
              leverage: Number.isFinite(lev) ? lev : null,
              updatedAt: now
            })
          } catch {}
        }
        hadAccountUpdate = true
        try { console.info('[USERDATA_WS_REHYDRATE_POS]', { count: positions.size }) } catch {}
      }
    } catch (e) {
      try { console.error('[USERDATA_WS_REHYDRATE_POS_ERR]', (e as any)?.message || e) } catch {}
    }
  }

  async function rehydrateOpenOrdersOnce(): Promise<void> {
    try {
      const api = getBinanceAPI() as any
      const list = await api.getAllOpenOrders()
      if (Array.isArray(list)) {
        for (const o of list) {
          try {
            const id = Number(o?.orderId ?? o?.orderID)
            const sym = String(o?.symbol || '')
            if (!id || !sym) continue
            const side = String(o?.side || '')
            const otype = String(o?.type || '')
            const price = Number(o?.price)
            const stopPrice = Number(o?.stopPrice)
            const tif = String(o?.timeInForce || '')
            const reduceOnly = Boolean(o?.reduceOnly ?? false)
            const closePosition = Boolean(o?.closePosition ?? false)
            const positionSideRaw = String(o?.positionSide || '')
            const positionSide = positionSideRaw === 'LONG' ? 'LONG' : positionSideRaw === 'SHORT' ? 'SHORT' : null
            const createdMs = Number((o as any)?.time)
            const updatedMs = Number((o as any)?.updateTime)
            const qty = Number(o?.origQty ?? o?.quantity ?? o?.qty)
            const clientOrderId = String((o as any)?.clientOrderId || '') || null
            openOrdersById.set(id, {
              orderId: id,
              symbol: sym,
              side,
              type: otype,
              qty: Number.isFinite(qty) ? qty : null,
              price: Number.isFinite(price) ? price : null,
              stopPrice: Number.isFinite(stopPrice) ? stopPrice : null,
              timeInForce: tif || null,
              reduceOnly,
              closePosition,
              positionSide,
              createdAt: Number.isFinite(createdMs) && createdMs > 0 ? new Date(createdMs).toISOString() : null,
              updatedAt: Number.isFinite(updatedMs) && updatedMs > 0 ? new Date(updatedMs).toISOString() : null,
              status: 'NEW',
              clientOrderId
            })
          } catch {}
        }
        hadOrderUpdate = true
        try { console.info('[USERDATA_WS_REHYDRATE_ORDERS]', { count: openOrdersById.size }) } catch {}
      }
    } catch (e) {
      try { console.error('[USERDATA_WS_REHYDRATE_ORDERS_ERR]', (e as any)?.message || e) } catch {}
    }
  }

  function parseAccountUpdate(msg: any) {
    try {
      const a = msg?.a
      if (!a) return
      const ps = Array.isArray(a?.P) ? a.P : []
      const now = Date.now()
      for (const p of ps) {
        const sym = String(p?.s || '')
        if (!sym) continue
        const pa = Number(p?.pa)
        const ep = Number(p?.ep)
        const psdRaw = String(p?.ps || '')
        const psd = psdRaw === 'LONG' ? 'LONG' : psdRaw === 'SHORT' ? 'SHORT' : null
        const lev = Number(p?.l || p?.leverage)
        positions.set(sym, {
          symbol: sym,
          positionAmt: Number.isFinite(pa) ? pa : 0,
          entryPrice: Number.isFinite(ep) ? ep : null,
          positionSide: psd,
          leverage: Number.isFinite(lev) ? lev : null,
          updatedAt: now
        })
      }
      hadAccountUpdate = true
    } catch {}
  }

  function upsertOrderFromUpdate(o: any) {
    try {
      const id = Number(o?.i)
      const sym = String(o?.s || '')
      if (!id || !sym) return
      const side = String(o?.S || '')
      const otype = String(o?.o || '')
      const price = Number(o?.p)
      const stopPrice = Number(o?.sp)
      const tif = String(o?.f || '')
      const reduceOnly = Boolean(o?.R ?? o?.reduceOnly ?? false)
      const closePosition = Boolean(o?.cp ?? o?.closePosition ?? false)
      const positionSideRaw = String(o?.ps || '')
      const positionSide = positionSideRaw === 'LONG' ? 'LONG' : positionSideRaw === 'SHORT' ? 'SHORT' : null
      const ts = Number(o?.T ?? o?.E ?? Date.now())
      const status = String(o?.X || '')
      const qty = Number(o?.q ?? o?.Q ?? o?.origQty)
      // Zachytit clientOrderId z různých možných polí
      const clientOrderId = String((o as any)?.c || (o as any)?.C || (o as any)?.clientOrderId || '') || null

      // Preserve first-seen creation time per orderId for accurate Age in UI
      const prev = openOrdersById.get(id)
      const createdCandidate = Number((o as any)?.O ?? (o as any)?.orderCreationTime ?? (o as any)?.T ?? (o as any)?.E)
      const createdMs = Number.isFinite(createdCandidate) && createdCandidate > 0 ? createdCandidate : ts
      const createdAt = (prev && typeof prev.createdAt === 'string')
        ? prev.createdAt
        : (Number.isFinite(createdMs) ? new Date(createdMs).toISOString() : null)

      const obj = {
        orderId: id,
        symbol: sym,
        side,
        type: otype,
        qty: Number.isFinite(qty) ? qty : null,
        price: Number.isFinite(price) ? price : null,
        stopPrice: Number.isFinite(stopPrice) ? stopPrice : null,
        timeInForce: tif || null,
        reduceOnly,
        closePosition,
        positionSide,
        createdAt: createdAt as string | null,
        updatedAt: Number.isFinite(ts) ? new Date(ts).toISOString() : null,
        status,
        clientOrderId
      }
      // Update or remove based on status
      if (status === 'NEW' || status === 'PARTIALLY_FILLED') {
        openOrdersById.set(id, obj)
      } else if (['FILLED','CANCELED','EXPIRED','REJECTED'].includes(status)) {
        openOrdersById.delete(id)
      } else {
        // generic update
        openOrdersById.set(id, obj)
      }
      hadOrderUpdate = true
    } catch {}
  }

  async function cancelSiblingExits(symbol: string, filledClientOrderId: string | null): Promise<void> {
    try {
      // Ignoruj externí fills
      if (!isInternalClientId(filledClientOrderId)) return
      
      // Najdi všechny interní exit objednávky pro daný symbol
      const siblingExits = Array.from(openOrdersById.values()).filter((o: any) => {
        if (o.symbol !== symbol) return false
        if (!isInternalClientId(o.clientOrderId)) return false
        // Je to exit objednávka? (SL nebo TP)
        const isExit = o.type && (/STOP/i.test(o.type) || /TAKE_PROFIT/i.test(o.type))
        return isExit
      })
      
      // Zrušit nalezené exit objednávky
      for (const exitOrder of siblingExits) {
        try {
          // Import getBinanceAPI dynamicky
          const { getBinanceAPI } = await import('../../trading/binance_futures')
          const api = getBinanceAPI() as any
          await api.cancelOrder({ symbol, orderId: exitOrder.orderId })
          try { console.info('[SIBLING_CANCEL]', { symbol, orderId: exitOrder.orderId, clientOrderId: exitOrder.clientOrderId }) } catch {}
        } catch (e: any) {
          try { console.error('[SIBLING_CANCEL_ERR]', { symbol, orderId: exitOrder.orderId, error: e?.message || e }) } catch {}
        }
      }
    } catch (e: any) {
      try { console.error('[CANCEL_SIBLING_EXITS_ERR]', { symbol, error: e?.message || e }) } catch {}
    }
  }

  function handleOrderTradeUpdate(msg: any) {
    const o = msg?.o
    if (!o) return
    upsertOrderFromUpdate(o)
    try {
      const symbol = String(o?.s || '')
      const status = String(o?.X || '')
      const orderId = Number(o?.i || 0)
      const side = String(o?.S || '')
      const otype = String(o?.o || '')
      const clientOrderId = String((o as any)?.c || (o as any)?.C || (o as any)?.clientOrderId || '') || null
      
      if (symbol) {
        if (status === 'CANCELED' || status === 'EXPIRED') {
          opts.audit({ type: 'cancel', symbol, orderId, side, otype, source: 'binance_ws', reason: status.toLowerCase(), payload: o })
        } else if (status === 'FILLED' || status === 'TRADE') {
          opts.audit({ type: 'filled', symbol, orderId, side, otype, source: 'binance_ws', reason: null, payload: o })
          // Sibling auto-cancel jen pro interní filled objednávky
          if (isInternalClientId(clientOrderId)) {
            cancelSiblingExits(symbol, clientOrderId).catch(() => {})
          }
        }
      }
    } catch {}
  }

  const fetchListenKey = async (): Promise<string | null> => {
    try {
      const res = await fetch('https://fapi.binance.com/fapi/v1/listenKey', { method: 'POST', headers: { 'X-MBX-APIKEY': apiKey } })
      const j: any = await res.json()
      return j?.listenKey || null
    } catch { return null }
  }
  const keepAlive = async () => {
    if (!listenKey) return
    try { await fetch(`https://fapi.binance.com/fapi/v1/listenKey?listenKey=${listenKey}`, { method: 'PUT', headers: { 'X-MBX-APIKEY': apiKey } }) } catch {}
  }
  const scheduleKeepAlive = () => {
    if (refreshTimer) clearInterval(refreshTimer)
    refreshTimer = setInterval(() => { keepAlive().catch(()=>{}) }, keepaliveMs)
  }
  const connectWs = async () => {
    listenKey = await fetchListenKey()
    if (!listenKey) { try { console.error('[USERDATA_WS_LISTENKEY_FAIL]') } catch {}; setTimeout(connectWs, 5000); return }
    scheduleKeepAlive()
    const url = `wss://fstream.binance.com/ws/${listenKey}`
    try { console.info('[USERDATA_WS_CONNECT]', { url_end: url.slice(-8) }) } catch {}
    ws = new WebSocket(url)
    ws.on('open', () => { try { console.info('[USERDATA_WS_OPEN]') } catch {}; rehydratePositionsOnce().catch(()=>{}); rehydrateOpenOrdersOnce().catch(()=>{}) })
    ws.on('close', (code) => { try { console.warn('[USERDATA_WS_CLOSE]', { code }) } catch {}; reconnect() })
    ws.on('error', (e) => { try { console.error('[USERDATA_WS_ERROR]', (e as any)?.message || e) } catch {}; reconnect() })
    ws.on('message', (data) => { handleMessage(String(data)) })
  }
  const reconnect = () => {
    try { ws?.close() } catch {}
    ws = null
    setTimeout(connectWs, 3000)
  }
  const handleMessage = (raw: string) => {
    try {
      const msg = JSON.parse(raw)
      const ev = String(msg?.e || '')
      if (ev === 'ACCOUNT_UPDATE') {
        parseAccountUpdate(msg)
      } else if (ev === 'ORDER_TRADE_UPDATE') {
        handleOrderTradeUpdate(msg)
      }
    } catch {}
  }
  connectWs()
}

// Public accessors for server
export function getPositionsInMemory(): Array<{ symbol: string; positionAmt: number; entryPrice: number | null; positionSide: 'LONG'|'SHORT'|null; leverage: number | null; updatedAt: number }> {
  return Array.from(positions.values())
}
export function getOpenOrdersInMemory(): Array<any> {
  return Array.from(openOrdersById.values())
}
export function isUserDataReady(kind: 'positions' | 'orders' | 'any' = 'any'): boolean {
  if (kind === 'positions') return hadAccountUpdate
  if (kind === 'orders') return hadOrderUpdate
  return hadAccountUpdate || hadOrderUpdate
}
