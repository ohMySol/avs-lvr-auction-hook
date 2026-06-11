/* ============================================================
   View 2 — Pool Stats (placeholder)
   ============================================================ */

import { Icon } from "./ui.jsx";

function PoolView() {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
      minHeight: 340, gap: 18, textAlign: 'center' }}>
      <div style={{ width: 56, height: 56, borderRadius: 14, background: 'var(--surface-2)',
        border: '1px solid var(--line-2)', display: 'grid', placeItems: 'center', color: 'var(--text-mut)' }}>
        <Icon name="activity" size={26} />
      </div>
      <div>
        <div style={{ fontSize: 20, fontWeight: 600, marginBottom: 8 }}>Coming soon</div>
        <div style={{ color: 'var(--text-mut)', fontSize: 14, maxWidth: 360 }}>
          Live pool analytics — price vs. CEX, LVR captured per block, and ArbitrageSettled event feed.
        </div>
      </div>
    </div>
  );
}

export { PoolView };
