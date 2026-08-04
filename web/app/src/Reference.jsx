import ANN from './annotations.json'

// Generated from the same file the tooltips read, so the text version can never
// drift from the interactive one - and it stays searchable and printable.
function Rows({ states, setHot }) {
  return Object.entries(ANN)
    .filter(([, d]) => !!d.s === states)
    .map(([k, d]) => (
      <tr key={k} onMouseEnter={() => setHot(k)} onMouseLeave={() => setHot(null)}>
        <td className="name">{d.t}</td>
        <td>
          {d.d}
          {d.n && <em className="note-inline">{d.n}</em>}
        </td>
        <td>{d.c ? <code>{d.c}</code> : '—'}</td>
      </tr>
    ))
}

export default function Reference({ setHot }) {
  return (
    <div>
      <div className="card">
        <h2>Every control</h2>
        <table>
          <thead>
            <tr><th style={{ width: 150 }}>Control</th><th>What it does</th><th style={{ width: 280 }}>Command line</th></tr>
          </thead>
          <tbody><Rows states={false} setHot={setHot} /></tbody>
        </table>
      </div>
      <div className="card">
        <h2>Every state indicator</h2>
        <table>
          <thead>
            <tr><th style={{ width: 150 }}>Indicator</th><th>What it tells you</th><th style={{ width: 280 }}>Read from</th></tr>
          </thead>
          <tbody><Rows states={true} setHot={setHot} /></tbody>
        </table>
      </div>
    </div>
  )
}
