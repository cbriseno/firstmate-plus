// Narrow owner extension for a lossless inverse absent from tasks-axi's CLI.
// Uses the installed canonical parser and its SAME backlog lock/atomic writer.
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const source = process.argv[2];
const {parseBacklog, renderBacklog, renderTaskLines} = await import(pathToFileURL(source + '/backends/markdown-grammar.js'));
const {withLock, atomicWrite} = await import(pathToFileURL(source + '/backends/lock.js'));
await withLock(input.path, () => {
  if (fs.lstatSync(input.path).isSymbolicLink()) throw new Error('unsafe backlog path');
  const doc = parseBacklog(fs.readFileSync(input.path, 'utf8'));
  const found = doc.sections.flatMap(s => s.entries).filter(e => e.task?.id === input.id);
  if (found.length !== 1 || found[0].task.priority !== input.expected) throw new Error('priority changed before restore');
  const entry = found[0];
  delete entry.task.priority;
  // Keep body bytes and every unrelated entry unchanged.
  entry.raw[0] = renderTaskLines(entry.task)[0];
  const text = renderBacklog(doc);
  const actual = parseBacklog(text).sections.flatMap(s => s.entries).find(e => e.task?.id === input.id)?.task;
  if (actual?.priority !== undefined) throw new Error('priority restore not confirmed');
  atomicWrite(input.path, text);
});
console.log(JSON.stringify({state: 'applied'}));
