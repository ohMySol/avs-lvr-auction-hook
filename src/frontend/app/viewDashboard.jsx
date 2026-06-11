/* ============================================================
   View 1 — LP Dashboard
   ============================================================ */

import { formatUnits } from "viem";
import { EA } from "./data.js";
import { Icon, Card, Stat, Pill, Btn, TokenRow, AreaChart } from "./ui.jsx";
import { IS_LIVE, IS_TESTNET } from "./chain/deployment.js";
import { useWallet, useEarned, useFaucet, usePositionAmounts, DEC0 } from "./chain/hooks.js";

const fmtLiq = (l) =>
  new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 2 }).format(Number(l));

function ConnectPrompt({ onConnect }) {
  return (
    <div className="card" style={{ textAlign: 'center', padding: '60px 30px', maxWidth: 460, margin: '40px auto' }}>
      <div style={{ width: 46, height: 46, borderRadius: 12, background: 'var(--surface-2)',
        border: '1px solid var(--line-2)', display: 'grid', placeItems: 'center', margin: '0 auto 18px', color: 'var(--text-mut)' }}>
        <Icon name="wallet" size={22} />
      </div>
      <h2 style={{ margin: '0 0 8px', fontSize: 19, fontWeight: 600 }}>Connect to view your position</h2>
      <p style={{ margin: '0 0 22px', color: 'var(--text-mut)', fontSize: 14 }}>
        EigenAuction reads your in-range liquidity and the LVR rebate accrued to it. Read-only — no signature needed to view.
      </p>
      <Btn onClick={onConnect}><Icon name="wallet" size={16} /> Connect wallet</Btn>
    </div>
  );
}

function DashboardView({ connected, onConnect, rewards, position, onManage, onToast }) {
  // Hooks run unconditionally (before the early return) to satisfy the rules of hooks; they no-op
  // until a live deployment + connected account are present.
  const { address } = useWallet();
  const earned = useEarned(address);
  const { faucet, isPending: faucetPending } = useFaucet();
  const livePos = usePositionAmounts(address);  // null when no live position

  if (!connected) return <ConnectPrompt onConnect={onConnect} />;

  const live = IS_LIVE && connected;
  const hasLivePos = live && livePos != null;
  // When IS_LIVE but no position yet, show zeros — not the mock numbers.
  const noPos = live && livePos == null;

  // ---- position values ----
  const P = position;
  const amount0     = hasLivePos ? livePos.amount0Human : (noPos ? 0 : P.amountUsdc);
  const amount1     = hasLivePos ? livePos.amount1Human : (noPos ? 0 : P.amountEth);
  const poolSharePct = hasLivePos ? (livePos.poolShareBps / 100).toFixed(2) : (noPos ? '0.00' : (P.poolShareBps / 100).toFixed(2));
  const liquidityLabel = hasLivePos ? fmtLiq(livePos.posLiquidity) : (noPos ? '—' : (P.liquidityNum + 'M'));
  const valueC0 = hasLivePos ? livePos.valueC0 : (noPos ? 0 : (P.amountEth * EA.seed.poolPrice + P.amountUsdc));
  const inRange = true;  // full-range position is always in range

  // ---- rewards ----
  const usdcRwd = live ? Number(formatUnits(earned.amount ?? 0n, earned.dec)) : rewards.usdc;
  const hasRewards = usdcRwd > 1e-9;

  const doFaucet = async () => {
    try { await faucet(); onToast && onToast('Test tokens sent to your wallet'); }
    catch { onToast && onToast('Faucet failed'); }
  };

  return (
    <>
      <div className="grid cols-2">
        {/* LEFT — position + history */}
        <div className="grid" style={{ alignContent: 'start' }}>
          <Card
            title="Your position"
            right={<div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              {noPos
                ? <Pill kind="amb">○ no position</Pill>
                : <Pill kind="acc">● in range</Pill>}
              <div style={{ display: 'flex', gap: 6 }}>
                {IS_TESTNET && <button className="mini-btn" onClick={doFaucet} disabled={faucetPending}>{faucetPending ? '…' : 'Faucet'}</button>}
                <button className="mini-btn" onClick={() => onManage('add')}>+ Add</button>
                {!noPos && <button className="mini-btn" onClick={() => onManage('remove')}>− Remove</button>}
              </div>
            </div>}
          >
            <div className="grid cols-3" style={{ gap: 14, marginBottom: 4 }}>
              <Stat sm label="Range" value={hasLivePos ? 'Full' : EA.fmtNum(P.priceLower, 0)} sub={hasLivePos ? 'range' : ('→ ' + EA.fmtNum(P.priceUpper, 0))} />
              <Stat sm label="Liquidity (L)" value={liquidityLabel} sub={'pool share ' + poolSharePct + '%'} />
              <Stat sm label="Value" value={EA.fmtCompact(valueC0)} sub="in currency0" />
            </div>
            <div className="divider" />
            <TokenRow sym="USDC" full="currency0" ico="usdc" amt={EA.fmtNum(amount0, 2)} usd={EA.fmtUsd(amount0)} />
            <TokenRow sym="ETH" full="currency1" ico="eth" amt={EA.fmtNum(amount1, 4)} usd={EA.fmtUsd(amount1 * (livePos?.poolPrice ? 1 / livePos.poolPrice : EA.seed.poolPrice))} />
          </Card>

          <Card title="Rebate accrual" sub="Cumulative LVR rebate to this position · 30d" right={<Pill kind="acc">{EA.fmtCompact(EA.HISTORY[EA.HISTORY.length-1].cum)}</Pill>}>
            <AreaChart data={EA.HISTORY} />
            <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11, color: 'var(--text-dim)',
              fontFamily: 'var(--font-mono)', marginTop: 6 }}>
              <span>30d ago</span><span>today</span>
            </div>
          </Card>
        </div>

        {/* RIGHT — rewards */}
        <div className="grid" style={{ alignContent: 'start' }}>
          <Card
            title="Pending rewards"
            sub="hook.earned(key, you, tickLower, tickUpper, salt)"
            style={{ borderColor: hasRewards ? 'color-mix(in oklab, var(--accent) 32%, var(--line))' : 'var(--line)' }}
          >
            <div className="stat" style={{ marginBottom: 14 }}>
              <div className="label">Accrued (currency0)</div>
              <div className="value pos" style={{ fontSize: 34 }}>{EA.fmtUsd(usdcRwd)}</div>
            </div>
            <TokenRow sym="USDC" full="USD Coin" ico="usdc" amt={EA.fmtNum(usdcRwd, 2)} usd={EA.fmtUsd(usdcRwd)} />
            <div className="hint" style={{ textAlign: 'center', marginTop: 18 }}>
              Rewards are paid automatically when you remove liquidity
            </div>
          </Card>

          <Card title="Lifetime earned">
            <div className="kvs">
              <div className="kv"><span className="k">ETH claimed</span><span className="v pos">{EA.fmtNum(rewards.lifetimeEth, 4)} Ξ</span></div>
              <div className="kv"><span className="k">USDC claimed</span><span className="v pos">{EA.fmtNum(rewards.lifetimeUsdc, 2)}</span></div>
              <div className="kv"><span className="k">Claim count</span><span className="v">{rewards.claims}</span></div>
              <div className="divider" style={{ margin: '4px 0' }} />
              <div className="kv"><span className="k">vs. fees-only (est.)</span><span className="v pos">+34.2%</span></div>
            </div>
          </Card>
        </div>
      </div>
    </>
  );
}

export { DashboardView };
