import ANN from './annotations.json'

// The right-hand rail. This is the guide, fused into the live panel: hovering a
// real control explains it, so the documentation and the thing it documents
// cannot drift apart.
export default function Detail({ id }) {
  const d = id && ANN[id]
  if (!d) {
    return (
      <aside className="detail">
        <div className="kicker">Detail</div>
        <h3>Point at a control</h3>
        <p className="empty">
          Hover or tab to anything on the left and this panel explains what it does,
          what it runs, and the caveat if it has one.
        </p>
      </aside>
    )
  }
  return (
    <aside className="detail" aria-live="polite">
      <div className="kicker">{d.g}{d.s ? ' · indicator' : ''}</div>
      <h3>{d.t}</h3>
      <p>{d.d}</p>
      {d.c && (
        <div>
          <span className="cli-k">{d.s ? 'Read from' : 'Command line'}</span>
          <div className="cli">{d.c}</div>
        </div>
      )}
      {d.n && <div className={'note' + (d.danger ? ' danger' : '')}>{d.n}</div>}
    </aside>
  )
}
