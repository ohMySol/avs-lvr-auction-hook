/* ============================================================
   EigenAuction — app shell, nav, wallet, live sim, tweaks
   ============================================================ */
import React, { useState, useEffect, useRef } from "react";
import { EA } from "./data.js";
import { Icon } from "./ui.jsx";
import { HomeView } from "./viewHome.jsx";
import { DashboardView } from "./viewDashboard.jsx";
import { PoolView } from "./viewPool.jsx";
import { TradeView } from "./viewTrade.jsx";
import { LiquidityModal } from "./liquidityModal.jsx";
import {
  useTweaks, TweaksPanel, TweakSection, TweakColor, TweakRadio, TweakSelect,
} from "./tweaks-panel.jsx";
import { useWallet, useChainInfo } from "./chain/hooks.js";
import { IS_LIVE } from "./chain/deployment.js";

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "accent": "#2fe0a8",
  "mode": "dark",
  "density": "regular",
  "font": "Space Grotesk"
}/*EDITMODE-END*/;

/* palettes for each mode, accent injected separately */
const MODES = {
  dark: {
    '--bg': '#0c0e12', '--bg-2': '#121519', '--surface': '#15181e', '--surface-2': '#1a1e25',
    '--line': '#242932', '--line-2': '#2e343f', '--text': '#e8ebf0', '--text-mut': '#8a93a3', '--text-dim': '#5c6472',
  },
  light: {
    '--bg': '#f4f5f3', '--bg-2': '#ecedea', '--surface': '#ffffff', '--surface-2': '#f6f7f5',
    '--line': '#e2e4e0', '--line-2': '#d3d6d1', '--text': '#15181c', '--text-mut': '#5a6470', '--text-dim': '#8b94a0',
  },
};
const DENSITY = {
  compact: { '--pad': '16px', '--gap': '12px' },
  regular: { '--pad': '22px', '--gap': '18px' },
  comfy:   { '--pad': '28px', '--gap': '24px' },
};
const FONTS = {
  'Space Grotesk': "'Space Grotesk', system-ui, sans-serif",
  'Geist': "'Geist', system-ui, sans-serif",
  'IBM Plex Sans': "'IBM Plex Sans', system-ui, sans-serif",
};

function accentInk(hex) {
  // dark ink for light accents
  const c = hex.replace('#', '');
  const r = parseInt(c.slice(0,2),16), g = parseInt(c.slice(2,4),16), b = parseInt(c.slice(4,6),16);
  const lum = (0.299*r + 0.587*g + 0.114*b) / 255;
  return lum > 0.55 ? '#04140e' : '#ffffff';
}

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [view, setView] = useState('home');
  // Real wallet via wagmi when a deployment is wired in; a mock toggle keeps the design demo usable
  // without a chain (IS_LIVE === false).
  const wallet = useWallet();
  const { blockNumber: liveBlock, chainName } = useChainInfo();
  const [mockConnected, setMockConnected] = useState(false);
  const connected = IS_LIVE ? wallet.isConnected : mockConnected;
  const [toasts, setToasts] = useState([]);
  // liquidity position (mutable)
  const [position, setPosition] = useState({
    amountEth: 5.812, amountUsdc: 12480.0,
    priceLower: 3250.0, priceUpper: 3610.0,
    liquidityNum: 8.42, poolShareBps: 42,
  });
  const [liqOpen, setLiqOpen] = useState(false);
  const [liqMode, setLiqMode] = useState('add');

  // live sim state
  const [block, setBlock] = useState(EA.seed.block);
  const [poolPrice, setPoolPrice] = useState(EA.seed.poolPrice);
  const [cexPrice, setCexPrice] = useState(EA.seed.cexPrice);
  const [totalLvr, setTotalLvr] = useState(EA.seed.totalLvrUsd);
  const [arbCount, setArbCount] = useState(EA.seed.arbCount);
  const [events, setEvents] = useState(EA.EVENTS);
  const [countdown, setCountdown] = useState(12);
  const [rewards, setRewards] = useState({ ...EA.REWARDS });

  // apply theme tokens
  useEffect(() => {
    const root = document.documentElement;
    const pal = MODES[t.mode] || MODES.dark;
    Object.entries(pal).forEach(([k, v]) => root.style.setProperty(k, v));
    Object.entries(DENSITY[t.density] || DENSITY.regular).forEach(([k, v]) => root.style.setProperty(k, v));
    root.style.setProperty('--accent', t.accent);
    root.style.setProperty('--accent-ink', accentInk(t.accent));
    root.style.setProperty('--font-ui', FONTS[t.font] || FONTS['Space Grotesk']);
  }, [t.mode, t.density, t.accent, t.font]);

  // block / price / event simulation
  useEffect(() => {
    const tick = setInterval(() => {
      setCountdown((c) => {
        if (c <= 1) {
          // new block: settle an arb
          const newBlock = (b => { setBlock(b + 1); return b + 1; });
          setBlock((b) => b + 1);
          // jitter prices, occasionally close the gap
          setPoolPrice((p) => +(p + (Math.random() - 0.45) * 1.6).toFixed(2));
          setCexPrice((p) => +(p + (Math.random() - 0.5) * 2.0).toFixed(2));
          // ~70% of blocks have a settled arb
          if (Math.random() < 0.72) {
            setEvents((evs) => {
              const ev = EA.makeEvent(EA.seed.block + (evs.length ? 1 : 0), 0);
              ev.block = (evs[0] ? evs[0].block : EA.seed.block) + 1;
              ev.fresh = true;
              setTotalLvr((v) => v + ev.usd);
              setArbCount((n) => n + 1);
              // a slice accrues to our position if in range
              if (EA.seed.poolPrice >= EA.POSITION.priceLower && EA.seed.poolPrice <= EA.POSITION.priceUpper) {
                setRewards((r) => ({
                  ...r,
                  eth: r.eth + (ev.lvr.token === 'ETH' ? ev.lvr.amt : ev.usd / EA.seed.poolPrice) * 0.0042,
                  usdc: r.usdc + (ev.lvr.token === 'USDC' ? ev.lvr.amt : 0) * 0.0042,
                }));
              }
              const next = [ev, ...evs.map((e) => ({ ...e, fresh: false, agoSec: e.agoSec + 12 }))].slice(0, 10);
              return next;
            });
          }
          return 12;
        }
        return c - 1;
      });
    }, 1000);
    return () => clearInterval(tick);
  }, []);

  function pushToast(msg) {
    const id = Math.random();
    setToasts((ts) => [...ts, { id, msg }]);
    setTimeout(() => setToasts((ts) => ts.filter((x) => x.id !== id)), 3400);
  }

  function connect() {
    if (IS_LIVE) { wallet.connect(); return; }
    setMockConnected(true);
    pushToast('Wallet connected · 0x7Ad4…91cE');
  }

  function disconnect() {
    if (IS_LIVE) { wallet.disconnect(); return; }
    setMockConnected(false);
    pushToast('Wallet disconnected');
  }

  const NAV = [
    ['home', 'Home', 'spark'],
    ['dashboard', 'LP Dashboard', 'layers'],
    ['pool', 'Pool Stats', 'activity'],
    ['trade', 'Trade', 'send'],
  ];

  const HEADS = {
    dashboard: ['LP Dashboard', 'Your in-range liquidity and the LVR rebate the auction has routed back to it.'],
    pool: ['Pool Stats', EA.POOL.pair + ' · 0.05% — first-arb auction activity and value recaptured from MEV.'],
    trade: ['Trade', EA.POOL.pair + ' · swaps are auctioned to searchers, not front-run — LVR is captured for LPs.'],
  };

  function openManage(mode) { setLiqMode(mode); setLiqOpen(true); }

  return (
    <div className="app">
      {/* top bar */}
      <header className="topbar">
        <div className="brand" onClick={() => setView('home')} style={{ cursor: 'pointer' }}>
          <svg className="brand-mark" width="27" height="27" viewBox="0 0 64 64" aria-label="EigenAuction">
            <rect x="11" y="40" width="13" height="12" rx="3" fill="var(--line-2)" />
            <rect x="26" y="28" width="13" height="24" rx="3" fill="color-mix(in oklab, var(--accent) 55%, var(--line-2))" />
            <rect x="41" y="14" width="13" height="38" rx="3" fill="var(--accent)" />
          </svg>
          <span className="name">Eigen<b>Auction</b></span>
          <span className="tag">v4 hook</span>
        </div>
        <nav className="nav">
          {NAV.map(([id, label, ico]) => (
            <button key={id} className={view === id ? 'active' : ''} onClick={() => setView(id)}>
              <span className="dot" /> {label}
            </button>
          ))}
        </nav>
        <span className="spacer" />
        <span className="blockchip">
          <span className="live" />
          {IS_LIVE && liveBlock != null
            ? <>block #{liveBlock.toLocaleString()} · {chainName}</>
            : <>block #{block.toLocaleString()} · next {countdown}s</>}
        </span>
        {connected ? (
          <button className="wallet connected" onClick={disconnect}>
            <span className="avatar" /> {IS_LIVE && wallet.address ? EA.shortAddr(wallet.address) : '0x7Ad4…91cE'}
          </button>
        ) : (
          <button className="wallet" onClick={connect}><Icon name="wallet" size={16} /> Connect</button>
        )}
      </header>

      {/* main */}
      {view === 'home' ? (
        <HomeView go={setView} totalLvr={totalLvr} arbCount={arbCount} />
      ) : (
      <main className="main">
        <div className="page-head">
          <h1>{HEADS[view][0]}</h1>
          <p>{HEADS[view][1]}</p>
        </div>

        {view === 'dashboard' && (
          <DashboardView connected={connected} onConnect={connect} rewards={rewards} position={position} onManage={openManage} onToast={pushToast} />
        )}
        {view === 'pool' && (
          <PoolView poolPrice={poolPrice} cexPrice={cexPrice} totalLvr={totalLvr} arbCount={arbCount} events={events} />
        )}
        {view === 'trade' && (
          <TradeView connected={connected} onConnect={connect} poolPrice={poolPrice} onToast={pushToast} />
        )}
      </main>
      )}

      {/* liquidity modal */}
      <LiquidityModal open={liqOpen} mode={liqMode} setMode={setLiqMode} position={position} poolPrice={poolPrice}
        onClose={() => setLiqOpen(false)}
        onApply={(np, msg) => { setPosition(np); pushToast(msg); }} />

      {/* toasts */}
      <div className="toast-wrap">
        {toasts.map((tt) => (
          <div className="toast" key={tt.id}><span className="ck"><Icon name="check" size={11} /></span>{tt.msg}</div>
        ))}
      </div>

      {/* tweaks */}
      <TweaksPanel title="Tweaks">
        <TweakSection label="Theme" />
        <TweakColor label="Accent" value={t.accent}
          options={['#2fe0a8', '#6aa0ff', '#c4ff4d', '#ff7a45', '#b89bff']}
          onChange={(v) => setTweak('accent', v)} />
        <TweakRadio label="Mode" value={t.mode} options={['dark', 'light']}
          onChange={(v) => setTweak('mode', v)} />
        <TweakSection label="Layout" />
        <TweakRadio label="Density" value={t.density} options={['compact', 'regular', 'comfy']}
          onChange={(v) => setTweak('density', v)} />
        <TweakSelect label="UI font" value={t.font} options={['Space Grotesk', 'Geist', 'IBM Plex Sans']}
          onChange={(v) => setTweak('font', v)} />
      </TweaksPanel>
    </div>
  );
}

export { App };
