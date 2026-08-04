// Regenerates the DATA block inside docs/token-stack-gui.html from
// src/annotations.json, which is the single source of truth for every
// annotation. Without this the standalone guide and the React panel would be
// two hand-maintained copies of the same prose, and they would drift.
//
// Runs automatically as part of `npm run build`.
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const source = resolve(here, '../src/annotations.json')
const target = resolve(here, '../../../../../docs/token-stack-gui.html')

const START = '/* @generated-from annotations.json - do not edit by hand */'
const END = '/* @end-generated */'

const data = JSON.parse(readFileSync(source, 'utf8'))
const html = readFileSync(target, 'utf8')

const a = html.indexOf(START)
const b = html.indexOf(END)
if (a === -1 || b === -1) {
  console.error(`Markers not found in ${target}. Expected:\n  ${START}\n  ...\n  ${END}`)
  process.exit(1)
}

const block = `${START}\nconst DATA = ${JSON.stringify(data, null, 2)};\n`
const next = html.slice(0, a) + block + html.slice(b)

if (next === html) {
  console.log(`sync-guide: docs/token-stack-gui.html already current (${Object.keys(data).length} annotations)`)
} else {
  writeFileSync(target, next, 'utf8')
  console.log(`sync-guide: rewrote docs/token-stack-gui.html (${Object.keys(data).length} annotations)`)
}
