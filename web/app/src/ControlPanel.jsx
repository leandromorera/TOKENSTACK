import { useCallback, useEffect, useRef, useState } from 'react'
import { getState, postRun, getJob, postCancel } from './api'
import FolderPicker from './FolderPicker'

// data-id ties a live control to its annotation in annotations.json. The `hot`
// prop is the currently-explained id, so the guide highlights in step with the
// detail rail.
function useHot(setHot) {
  return useCallback(
    (id) => ({
      'data-id': id,
      onMouseEnter: () => setHot(id),
      onMouseLeave: () => setHot(null),
      onFocus: () => setHot(id),
      onBlur: () => setHot(null),
    }),
    [setHot],
  )
}

const cx = (id, hot, base = '') => `${base}${hot === id ? ' hot' : ''}`.trim()

export default function ControlPanel({ hot, setHot, initialProject, defaults }) {
  const hp = useHot(setHot)

  const [project, setProject] = useState(initialProject)
  const [tools, setTools] = useState(defaults.tools || '')
  const [port, setPort] = useState('8787')
  const [label, setLabel] = useState('baseline')
  const [dryRun, setDryRun] = useState(false)
  const [skipProxy, setSkipProxy] = useState(false)
  const [upgrade, setUpgrade] = useState(false)
  const [removeTools, setRemoveTools] = useState(false)

  const [picking, setPicking] = useState(false)
  const [rows, setRows] = useState([])
  const [lines, setLines] = useState([])
  const [running, setRunning] = useState(false)
  const [status, setStatus] = useState('Ready')
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  const since = useRef(0)
  const logRef = useRef(null)

  const refresh = useCallback(async () => {
    if (!project || !tools) return
    try {
      const { rows } = await getState(project, tools, Number(port) || 8787)
      setRows(rows)
      setError('')
    } catch (e) {
      setError(String(e.message || e))
    }
  }, [project, tools, port])

  // Debounced so typing a path does not fire a request per keystroke.
  useEffect(() => {
    const t = setTimeout(refresh, 350)
    return () => clearTimeout(t)
  }, [refresh])

  // Poll while a job runs. 400 ms is imperceptible for a log and avoids the
  // websocket dependency this otherwise does not need.
  useEffect(() => {
    if (!running) return
    const id = setInterval(async () => {
      try {
        const snap = await getJob(since.current)
        if (snap.lines.length) {
          since.current = snap.total
          setLines((prev) => [...prev, ...snap.lines].slice(-4000))
        }
        if (!snap.running) {
          setRunning(false)
          setStatus(snap.exit === 0 ? 'Finished' : `Finished (exit ${snap.exit})`)
          refresh()
        }
      } catch (e) {
        setRunning(false)
        setError(String(e.message || e))
      }
    }, 400)
    return () => clearInterval(id)
  }, [running, refresh])

  useEffect(() => {
    if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight
  }, [lines])

  // projectOverride lets the folder picker act on where you have browsed to
  // rather than on the path still sitting in the box behind it.
  async function run(action, confirmMsg, projectOverride) {
    if (confirmMsg && !window.confirm(confirmMsg)) return
    setError('')
    setNotice('')
    try {
      const res = await postRun({
        action, project: projectOverride || project, tools, port: Number(port) || 8787,
        dryRun, skipProxy, upgrade, removeTools, label,
      })
      // Detached actions (proxy, folder) report back immediately and start no job.
      if (action === 'proxy' || action === 'folder') {
        setNotice(res.message)
        setTimeout(refresh, 1200)
        return
      }
      since.current = 0
      setLines([])
      setRunning(true)
      setStatus(action)
    } catch (e) {
      setError(String(e.message || e))
    }
  }

  const projectBad = rows.some((r) => r.key === 'Project' && r.state === 'bad')
  const busy = running

  return (
    <div>
      {error && <div className="banner err">{error}</div>}
      {notice && <div className="banner info">{notice}</div>}

      <div className="card">
        <h2>Project</h2>
        <div className="row">
          <input type="text" className={cx('project-box', hot, 'grow')} {...hp('project-box')}
                 value={project} onChange={(e) => setProject(e.target.value)}
                 spellCheck={false} placeholder="C:\code\my-app" />
          {/* A browser file dialog cannot return a real path, so this walks the
              server's filesystem over /api/browse instead of opening a dialog
              whose result the page would not be allowed to read. */}
          <button className={cx('folder-btn', hot, 'b')} {...hp('folder-btn')}
                  onClick={() => setPicking(true)}>Open folder...</button>
        </div>
        {picking && (
          <FolderPicker start={project} onPick={setProject}
                        onExplorer={(p) => run('folder', null, p)}
                        onClose={() => setPicking(false)} />
        )}
      </div>

      <div className="card">
        <h2>Options</h2>
        <div className="row">
          <label className={cx('dryrun-chk', hot, 'chk')} {...hp('dryrun-chk')}>
            <input type="checkbox" checked={dryRun} onChange={(e) => setDryRun(e.target.checked)} />
            Dry run (write nothing)
          </label>
          <label className={cx('skipproxy-chk', hot, 'chk')} {...hp('skipproxy-chk')} style={{ marginLeft: 10 }}>
            <input type="checkbox" checked={skipProxy} onChange={(e) => setSkipProxy(e.target.checked)} />
            Skip proxy wiring
          </label>
          <label className={cx('upgrade-chk', hot, 'chk')} {...hp('upgrade-chk')} style={{ marginLeft: 10 }}>
            <input type="checkbox" checked={upgrade} onChange={(e) => setUpgrade(e.target.checked)} />
            Upgrade tool packages
          </label>
          <span className="lbl" style={{ marginLeft: 12 }}>Port</span>
          <input type="text" className={cx('port-box', hot)} {...hp('port-box')} style={{ width: 74 }}
                 value={port} onChange={(e) => setPort(e.target.value)} />
          <span className="lbl">Tools home</span>
          <input type="text" className={cx('tools-box', hot)} {...hp('tools-box')} style={{ width: 250 }}
                 value={tools} onChange={(e) => setTools(e.target.value)} spellCheck={false} />
        </div>
      </div>

      <div className="card">
        <h2>Install</h2>
        <div className="row">
          <button className={cx('preview-btn', hot, 'b')} {...hp('preview-btn')}
                  onClick={() => run('preview')} disabled={busy}>Preview (dry run)</button>
          <button className={cx('install-btn', hot, 'b primary')} {...hp('install-btn')}
                  onClick={() => run('install')} disabled={busy || projectBad}>Install</button>
          <button className={cx('uninstall-btn', hot, 'b danger')} {...hp('uninstall-btn')} disabled={busy}
                  onClick={() => run('uninstall',
                    `Remove the token stack configuration from\n\n${project}\n\n` +
                    'metrics.jsonl is kept either way.' +
                    (removeTools ? '\n\nThe shared venv will ALSO be deleted - other projects use it.' : ''))}>
            Uninstall
          </button>
          <label className={cx('removetools-chk', hot, 'chk')} {...hp('removetools-chk')}>
            <input type="checkbox" checked={removeTools} onChange={(e) => setRemoveTools(e.target.checked)} />
            also delete shared venv
          </label>
          <button className={cx('cancel-btn', hot, 'b')} {...hp('cancel-btn')} style={{ marginLeft: 12 }}
                  onClick={() => postCancel().catch((e) => setError(String(e.message || e)))}
                  disabled={!busy}>Cancel</button>
        </div>
      </div>

      <div className="card">
        <h2>Run and measure</h2>
        <div className="row">
          <button className={cx('proxy-btn', hot, 'b')} {...hp('proxy-btn')}
                  onClick={() => run('proxy')} disabled={busy}>Start proxy</button>
          <button className={cx('measure-btn', hot, 'b')} {...hp('measure-btn')}
                  onClick={() => run('measure')} disabled={busy}>Measure</button>
          <span className="lbl">label</span>
          <input type="text" className={cx('label-box', hot)} {...hp('label-box')} style={{ width: 130 }}
                 value={label} onChange={(e) => setLabel(e.target.value)} />
          <button className={cx('dashboard-btn', hot, 'b')} {...hp('dashboard-btn')} style={{ marginLeft: 8 }}
                  onClick={() => run('dashboard')} disabled={busy}>Dashboard</button>
          <button className={cx('graphify-btn', hot, 'b')} {...hp('graphify-btn')}
                  onClick={() => run('link-graphify')} disabled={busy}>Link graphify</button>
        </div>
      </div>

      <div className="card">
        <h2>
          Current state
          <button className={cx('refresh-btn', hot, 'b')} {...hp('refresh-btn')} onClick={refresh}
                  style={{ float: 'right', minHeight: 26, padding: '2px 11px', fontSize: 13 }}>
            Refresh
          </button>
        </h2>
        <div className="state">
          {rows.map((r) => (
            <div key={r.id} className={cx(r.id, hot, 'srow')} {...hp(r.id)} tabIndex={0}>
              <span className={'dot ' + r.state} />
              <span className="k">{r.key}</span>
              <span className="v" title={r.value}>{r.value}</span>
            </div>
          ))}
          {!rows.length && <div className="lbl">No state yet &mdash; set a project path.</div>}
        </div>
      </div>

      <div className="card">
        <h2>Output</h2>
        <div className={cx('log-box', hot, 'log')} {...hp('log-box')} ref={logRef} tabIndex={0}>
          {lines.length ? lines.join('\n') : 'Nothing has run yet. Preview is the safe first click.'}
        </div>
        <div className="footer">
          <div className={cx('progress', hot, 'bar')} {...hp('progress')}>{busy && <i />}</div>
          <div className={cx('status-text', hot, 'txt')} {...hp('status-text')}>{status}</div>
        </div>
      </div>
    </div>
  )
}
