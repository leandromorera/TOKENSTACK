// The session token is minted by server.py at startup and handed to this page
// in its URL. Every /api call must carry it, otherwise any website you happen to
// have open could POST to this port and run an installer.
const params = new URLSearchParams(location.search)

export const TOKEN = params.get('token') || ''
export const INITIAL_PROJECT = params.get('project') || ''

async function req(path, opts = {}) {
  const res = await fetch(path, {
    ...opts,
    headers: { 'X-Token': TOKEN, ...(opts.body ? { 'Content-Type': 'application/json' } : {}), ...opts.headers },
  })
  const text = await res.text()
  let data
  try { data = text ? JSON.parse(text) : {} } catch { data = { detail: text } }
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`)
  return data
}

export const getState = (project, tools, port) =>
  req(`/api/state?project=${encodeURIComponent(project)}&tools=${encodeURIComponent(tools)}&port=${port}`)

export const postRun  = (body)  => req('/api/run', { method: 'POST', body: JSON.stringify(body) })
export const getJob   = (since) => req(`/api/job?since=${since}`)
export const postCancel = ()    => req('/api/cancel', { method: 'POST' })
export const getDefaults = ()   => req('/api/defaults')
export const getBrowse = (path) => req(`/api/browse?path=${encodeURIComponent(path || '')}`)
