import { useEffect, useState } from 'react'
import ControlPanel from './ControlPanel'
import Reference from './Reference'
import Detail from './Detail'
import { INITIAL_PROJECT, TOKEN, getDefaults } from './api'

export default function App() {
  const [tab, setTab] = useState('panel')
  const [hot, setHot] = useState(null)
  const [defaults, setDefaults] = useState(null)
  const [fatal, setFatal] = useState('')

  useEffect(() => {
    if (!TOKEN) { setFatal('No session token in the URL. Start this from token-stack-web.ps1 or server.py, which prints the correct link.'); return }
    getDefaults().then(setDefaults).catch((e) => setFatal(String(e.message || e)))
  }, [])

  if (fatal) return <div className="shell"><div className="banner err">{fatal}</div></div>
  if (!defaults) return <div className="shell"><p>Connecting...</p></div>

  return (
    <div className="shell">
      <header className="top">
        <h1>Token stack</h1>
        <span className="sub">control panel &mdash; hover anything to see what it does</span>
      </header>

      <nav className="tabs">
        <button className={tab === 'panel' ? 'on' : ''} onClick={() => setTab('panel')}>Control panel</button>
        <button className={tab === 'ref' ? 'on' : ''} onClick={() => setTab('ref')}>Reference</button>
      </nav>

      <div className="layout">
        <div>
          {tab === 'panel'
            ? <ControlPanel hot={hot} setHot={setHot} initialProject={INITIAL_PROJECT || defaults.cwd} defaults={defaults} />
            : <Reference setHot={setHot} />}
        </div>
        <Detail id={hot} />
      </div>
    </div>
  )
}
