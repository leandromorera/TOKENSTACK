import { useEffect, useRef, useState } from 'react'
import { getBrowse } from './api'

// A browser file dialog cannot hand a real directory path back to a page, so
// this walks the server's filesystem over /api/browse instead. It browses the
// machine running server.py, which is the right end when the panel is reached
// through an SSH tunnel.
export default function FolderPicker({ start, onPick, onExplorer, onClose }) {
  const [path, setPath] = useState(start || '')
  const [parent, setParent] = useState(null)
  const [dirs, setDirs] = useState([])
  const [repo, setRepo] = useState(false)
  const [filter, setFilter] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const filterRef = useRef(null)

  useEffect(() => {
    let live = true
    setLoading(true)
    getBrowse(path)
      .then((d) => {
        if (!live) return
        setDirs(d.dirs)
        setParent(d.parent)
        setRepo(d.repo)
        setError('')
      })
      // A bad start path should land you somewhere useful, not in a dead modal.
      .catch((e) => {
        if (!live) return
        setError(String(e.message || e))
        setDirs([])
        setParent(path ? '' : null)
      })
      .finally(() => live && setLoading(false))
    return () => { live = false }
  }, [path])

  useEffect(() => { setFilter(''); filterRef.current?.focus() }, [path])

  // Escape closes, so the modal never traps you without a mouse.
  useEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const q = filter.trim().toLowerCase()
  const shown = q ? dirs.filter((d) => d.name.toLowerCase().includes(q)) : dirs

  // Enter picks the single remaining match - the reason the filter box exists.
  function onFilterKey(e) {
    if (e.key === 'Enter' && shown.length === 1) setPath(shown[0].path)
  }

  return (
    <div className="modal-bg" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal" role="dialog" aria-label="Choose a project folder">
        <h3>Choose a project folder</h3>

        <div className="crumb">
          <button className="b" onClick={() => setPath(parent ?? '')} disabled={parent === null}>
            Up
          </button>
          <input
            type="text" className="grow" value={path} spellCheck={false}
            placeholder="This PC - pick a drive below"
            onChange={(e) => setPath(e.target.value)}
          />
        </div>

        <input
          ref={filterRef} type="text" className="filter" value={filter}
          placeholder={`Search ${dirs.length} folder${dirs.length === 1 ? '' : 's'} here`}
          onChange={(e) => setFilter(e.target.value)} onKeyDown={onFilterKey}
        />

        {error && <div className="banner err">{error}</div>}

        <div className="dirlist">
          {loading && <div className="lbl pad">Reading...</div>}
          {!loading && !shown.length && (
            <div className="lbl pad">{dirs.length ? 'Nothing matches that.' : 'No subfolders here.'}</div>
          )}
          {!loading && shown.map((d) => (
            <button key={d.path} className="dirrow" onClick={() => setPath(d.path)} title={d.path}>
              <span className="ico">{d.repo ? '●' : '▸'}</span>
              <span className="nm">{d.name}</span>
              {d.repo && <span className="tag">git</span>}
            </button>
          ))}
        </div>

        <div className="modal-foot">
          <span className="lbl">
            {/* The installer needs a git repo to measure anything, so say so
                here rather than after the path is already committed. */}
            {path ? (repo ? 'git repository' : 'not a git repository') : ''}
          </span>
          <button className="b" disabled={!path} onClick={() => onExplorer(path)}>Open in Explorer</button>
          <button className="b" onClick={onClose}>Cancel</button>
          <button className="b primary" disabled={!path} onClick={() => { onPick(path); onClose() }}>
            Use this folder
          </button>
        </div>
      </div>
    </div>
  )
}
