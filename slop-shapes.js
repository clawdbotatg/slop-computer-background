// Shared neon shapes for the slop-computer foreground + background screens.
// Each draw fn takes a 2D context and screen coords so both pages render identically.

let compImg = null, compReady = false;
export function loadComputer(src = 'computer.png') {
  compImg = new Image();
  compImg.onload = () => { compReady = true; };
  compImg.src = src;
}
export function drawComputer(ctx, cx, cy, size, alpha) {
  if (!compReady) return;
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.shadowColor = '#ff3ec9';
  ctx.shadowBlur = 24;
  ctx.drawImage(compImg, cx - size / 2, cy - size / 2, size, size);
  ctx.restore();
}

/* ---- Ethereum octahedron ---- */
const ETH = { r: 0.95, hTop: 1.75, hBot: 1.45, gap: 0.18, tilt: -0.30 };
const EV = (() => { const { r, hTop, hBot, gap } = ETH; const g = gap / 2;
  return [[0, hTop + g, 0], [r, g, 0], [0, g, r], [-r, g, 0], [0, g, -r],
          [0, -hBot - g, 0], [r, -g, 0], [0, -g, r], [-r, -g, 0], [0, -g, -r]]; })();
const EE = [[0,1],[0,2],[0,3],[0,4],[1,2],[2,3],[3,4],[4,1],[5,6],[5,7],[5,8],[5,9],[6,7],[7,8],[8,9],[9,6]];
const EF = [[0,1,2],[0,2,3],[0,3,4],[0,4,1],[5,6,7],[5,7,8],[5,8,9],[5,9,6]];
export function drawEth(ctx, cx, cy, scale, spin, alpha) {
  const cs = Math.cos(spin), sn = Math.sin(spin), ct = Math.cos(ETH.tilt), st = Math.sin(ETH.tilt);
  const P = EV.map(([x, y, z]) => { const x1 = x*cs + z*sn, z1 = -x*sn + z*cs;
    const y2 = y*ct - z1*st, z2 = y*st + z1*ct; return { x: cx + x1*scale, y: cy - y2*scale, z: z2 }; });
  const order = EF.map(f => ({ f, z: (P[f[0]].z + P[f[1]].z + P[f[2]].z) / 3 })).sort((a, b) => a.z - b.z);
  for (const { f, z } of order) {
    ctx.beginPath(); ctx.moveTo(P[f[0]].x, P[f[0]].y);
    ctx.lineTo(P[f[1]].x, P[f[1]].y); ctx.lineTo(P[f[2]].x, P[f[2]].y); ctx.closePath();
    ctx.fillStyle = `rgba(188,255,91,${(z > 0 ? 0.22 : 0.08) * alpha})`; ctx.fill();
  }
  ctx.shadowColor = '#bcff5b'; ctx.shadowBlur = 16;
  ctx.strokeStyle = `rgba(210,255,140,${0.95 * alpha})`;
  ctx.lineWidth = 2.2; ctx.lineJoin = 'round'; ctx.beginPath();
  for (const [a, b] of EE) { ctx.moveTo(P[a].x, P[a].y); ctx.lineTo(P[b].x, P[b].y); }
  ctx.stroke(); ctx.shadowBlur = 0;
}

/* ---- lobster claw ---- */
const CLAW_BASE = [[0.1,0.42],[-0.18,0.56],[-0.58,0.40],[-0.74,0.0],[-0.58,-0.40],[-0.18,-0.56],[0.1,-0.42]];
const CLAW_JAW  = [[0.0,0.06],[0.0,0.46],[0.46,0.56],[0.96,0.30],[1.22,0.04],[0.76,0.11],[0.36,0.09]];
const CLAW_JAW_LO = CLAW_JAW.map(([x, y]) => [x, -y]);
export function drawClaw(ctx, cx, cy, scale, handAngle, openAngle, alpha) {
  const chA = Math.cos(handAngle), shA = Math.sin(handAngle);
  function tf(px, py, jaw) { const cj = Math.cos(jaw), sj = Math.sin(jaw);
    const x1 = px*cj - py*sj, y1 = px*sj + py*cj;
    const x2 = x1*chA - y1*shA, y2 = x1*shA + y1*chA;
    return { x: cx + x2*scale, y: cy + y2*scale }; }
  function poly(pts, jaw) {
    ctx.beginPath(); const p0 = tf(pts[0][0], pts[0][1], jaw); ctx.moveTo(p0.x, p0.y);
    for (let i = 1; i < pts.length; i++) { const p = tf(pts[i][0], pts[i][1], jaw); ctx.lineTo(p.x, p.y); }
    ctx.closePath();
    ctx.fillStyle = `rgba(255,40,55,${0.14 * alpha})`; ctx.fill();
    ctx.strokeStyle = `rgba(255,75,85,${0.96 * alpha})`; ctx.lineWidth = 2.4; ctx.stroke();
  }
  ctx.save(); ctx.lineJoin = 'round'; ctx.lineCap = 'round';
  ctx.shadowColor = '#ff2a3a'; ctx.shadowBlur = 16;
  poly(CLAW_BASE, 0); poly(CLAW_JAW, +openAngle); poly(CLAW_JAW_LO, -openAngle);
  ctx.strokeStyle = `rgba(255,110,120,${0.6 * alpha})`; ctx.lineWidth = 1.4;
  for (const jaw of [+openAngle, -openAngle]) {
    const a = tf(0.1, jaw > 0 ? 0.16 : -0.16, jaw), b = tf(1.0, 0.05 * (jaw > 0 ? 1 : -1), jaw);
    ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
  }
  ctx.shadowBlur = 0; ctx.restore();
}
