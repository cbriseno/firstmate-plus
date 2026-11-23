#!/usr/bin/env bash
# Report navigation is generated and validated through the public CLI.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export FM_LIVE=0
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlsplit

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls, self.anchors = [], []
        self.forms, self.fields, self.choices = [], [], []
    def handle_starttag(self, tag, attrs):
        if tag == 'a': self.urls.append(dict(attrs)['href']); self.anchors.append(dict(attrs))
        if tag == 'form': self.forms.append(dict(attrs))
        if tag == 'input': self.fields.append(dict(attrs))
        if tag == 'select': self.choices.append(dict(attrs))

with tempfile.TemporaryDirectory() as tmp:
    home = Path(tmp)
    (home/'config').mkdir()
    (home/'config/deck-url').write_text('https://deck.example/base')
    (home/'data/task').mkdir(parents=True)
    (home/'data/task/presentation.json').write_text(json.dumps({'outcome_occurrence':'version & one'}))
    report = home/'data/task/report.html'
    report.write_text("""<html><body><header>Report</header><main><a href=../other/report.html>Other</a><script>const sample = '<a href="../other/report.html">';</script></main></body></html>""")
    command = [sys.executable, str(Path(sys.argv[1])/'bin/fm-report-actions.py'), str(report), '--task', 'task']
    def run(*args, ok=True):
        p = subprocess.run(command+list(args), env=dict(os.environ, FM_HOME=tmp, FM_CONFIG_OVERRIDE=str(home/'config'), FM_LANGUAGE=''), capture_output=True, text=True)
        assert (p.returncode == 0) == ok, p.stderr
        return p
    run('--check', ok=False)  # Existing nonempty HTML was insufficient.
    run('--option','approval','yes','Aprobar','--option','approval','research','Pedir más investigación')
    run('--check')
    first = report.read_text()
    assert 'https://deck.example/base/?task=other&amp;view=delivery' in first
    assert "const sample = '<a href=\"../other/report.html\">'" in first
    parser = Links(); parser.feed(first)
    queries = [parse_qs(urlsplit(url).query) for url in parser.urls]
    assert len(queries) == 5
    assert queries[0] == dict(task=['task'],view=['delivery'],item=['version & one'],do=['reviewed'])
    assert queries[1] == dict(task=['approval'],view=['call'],option=['yes'])
    assert queries[2] == dict(task=['approval'],view=['call'],option=['research'])
    assert queries[3]['do'] == ['lavish']
    assert queries[4] == dict(task=['other'], view=['delivery'])
    assert all(url.startswith('https://deck.example/base/?') for url in parser.urls)
    assert all(a.get('target') == '_blank' and a.get('rel') == 'noopener' for a in parser.anchors)  # Lavish frames cannot navigate the Deck.
    report.write_text(first.replace(' target="_blank"', ''))
    run('--check', ok=False)  # A framed Deck link is refused.
    report.write_text(first)
    report.write_text(first.replace('option=yes', 'option=other'))
    run('--check', '--option','approval','yes','Aprobar',ok=False)
    report.write_text(first)
    run('--option','approval','yes','Aprobar','--option','approval','research','Pedir más investigación')
    assert report.read_text() == first  # Repeating attachment does not duplicate the bar.
    run('--check','--occurrence','new',ok=False)
    report.write_text(first.replace('https://deck.example/base/', 'https://wrong.example/'))
    run('--check',ok=False)
    report.write_text('<details>'+first+'</details>')
    run('--check',ok=False)  # Hidden actions do not count.
    report.write_text(first)
    run('--question','approval','¿Aprobar el plan?', '--question','cleanup','¿Qué hacemos con los datos?',
        '--option','approval','yes','Aprobar', '--option','cleanup','research','Pedir más investigación')
    run('--check')
    batch=Links(); batch.feed(report.read_text())
    assert batch.forms == [dict(action='https://deck.example/base/', method='get', target='_blank')]
    assert {x['name']:x['value'] for x in batch.fields} == dict(task='task',view='delivery',item='version & one',do='decisions')
    assert [x['name'] for x in batch.choices] == ['r.approval','r.cleanup']
    choices = ('--question','approval','¿Aprobar el plan?', '--question','cleanup','¿Qué hacemos con los datos?',
               '--option','approval','yes','Aprobar', '--option','cleanup','research','Pedir más investigación')
    run('--check', *choices)
    generated = report.read_text()
    report.write_text(generated.replace('method="get" target="_blank"', 'method="get"'))
    run('--check', *choices, ok=False)  # A framed Deck form is refused.
    report.write_text(generated.replace('value="research"', 'value="other"'))
    run('--check', *choices, ok=False)
    report.write_text(generated.replace('<select name="r.cleanup"', '<select hidden name="r.cleanup"'))
    run('--check', *choices, ok=False)
    report.write_text(generated)
    (home/'config/language').write_text('es')
    report.write_text('<html lang="en"><body><header>Report</header></body></html>')
    run()
    assert 'Reviewed' in report.read_text() and 'Open in Lavish' in report.read_text()
    assert 'No decision is needed.' in report.read_text()
    (home/'config/language').write_text('en')
    run('--language', 'es')
    assert 'Revisado' in report.read_text() and 'Abrir en Lavish' in report.read_text()
    assert 'No hay ninguna decisión pendiente.' in report.read_text()
    assert '<html lang="es">' in report.read_text()
    run('--check', '--language', 'en', ok=False)
    run()  # A later regeneration uses the saved request language.
    assert 'Revisado' in report.read_text()
    run('--language', 'en')
    assert 'Reviewed' in report.read_text() and 'Revisado' not in report.read_text()
    report.write_text('<html><body><header>Report</header></body></html>')
    (home/'config/language').write_text('es-MX')
    run()
    assert 'Revisado' in report.read_text()
    assert '<html lang="es-MX">' in report.read_text()
    report.write_text('<body><header>Informe existente</header></body>')
    run()
    assert report.read_text().startswith('<html lang="es-MX">')
    assert 'Informe existente' in report.read_text()
    report.write_text('<html lang="es"><body><header>Informe</header></body></html>')
    (home/'config/language').write_text('en')
    run()
    assert 'Revisado' in report.read_text()
    run('--deck','javascript:alert(1)',ok=False)
    report.write_text('<html><body><a href="../other/report.html">Other</a></body></html>')
    run('--deck','')
    assert str(home/'data/other/report.html') in report.read_text()
    run('--check','--deck','')  # Unconfigured home has an explicit manual fallback.
    (home/'config/deck-url').unlink()
    before = report.read_text()
    run()
    missing = run('--check')
    assert 'Deck address missing' in missing.stdout
    assert 'Firstmate' in report.read_text()
    (home/'data/task/launch-brief.md').write_text('Deck address for report links: https://deck.example/base\n')
    # A supplied route works for both an existing report and a new report, even
    # when no destination is configured. Reopening retains its actions.
    for lang, label, title in [('en', 'Reviewed', 'Report'), ('es', 'Revisado', 'Informe')]:
        existing = f"<html lang='{lang}'><body><header>{title}<nav class='sticky report-actions'>Old</nav></header></body></html>"
        new = f'<html lang="{lang}"><body><header>{title}</header></body></html>'
        for body in (existing, new):
            report.write_text(body)
            run('--language', lang)
            run('--language', lang, '--check')
            reopened = report.read_text()
            assert label in reopened and 'Old</nav>' not in reopened
            assert 'do=reviewed' in reopened and 'do=lavish' in reopened

print('PASS: missing, visible, stale and hidden actions; encoded decisions; idempotence; brief route without configuration')
PY

# Exercise the report checker with the short informational answer in both languages.
if command -v node >/dev/null 2>&1; then
  node - "$ROOT/worker/report-check.js" <<'JS'
const fs = require('fs');
const check = eval(fs.readFileSync(process.argv[2], 'utf8'));
const card = text => ({innerText: text, querySelector: () => null});
global.getComputedStyle = () => ({visibility: 'visible'});
function result(lang, answer) {
  global.document = {documentElement: {lang}, body: {innerText: answer},
    querySelectorAll: selector => selector === '#en-1-minuto .card'
      ? [card('What happened in this report'), card('What this means for readers'), card(answer)] : []};
  const checked = check();
  if (!checked.one_minute_block) throw Error('short informational answer rejected');
  return checked.third_answer_is_decision_or_informative;
}
for (const [lang, answer, expected] of [
  ['en', 'nothing, informational only', true], ['es', 'nada, solo informativo', true],
  ['en', 'nada, solo informativo', false], ['es', 'nothing, informational only', false]
]) {
  if (result(lang, answer) !== expected) throw Error(`${lang}: ${answer}`);
}
console.log('PASS: report checker uses the document language');
JS
else
  printf '%s\n' 'SKIP: report checker requires node'
fi
