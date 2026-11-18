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
        self.urls = []
        self.forms, self.fields, self.choices = [], [], []
    def handle_starttag(self, tag, attrs):
        if tag == 'a': self.urls.append(dict(attrs)['href'])
        if tag == 'form': self.forms.append(dict(attrs))
        if tag == 'input': self.fields.append(dict(attrs))
        if tag == 'select': self.choices.append(dict(attrs))

with tempfile.TemporaryDirectory() as tmp:
    home = Path(tmp)
    (home/'config').mkdir()
    (home/'config/deck-url').write_text('https://deck.example/base')
    (home/'data/task').mkdir(parents=True)
    (home/'data/task/presentation.json').write_text(json.dumps({'outcome_occurrence':'version & one'}))
    report = home/'report.html'
    report.write_text('<html><body><header>Report</header><main>Evidence</main></body></html>')
    command = [sys.executable, str(Path(sys.argv[1])/'bin/fm-report-actions.py'), str(report), '--task', 'task']
    def run(*args, ok=True):
        p = subprocess.run(command+list(args), env=dict(os.environ, FM_HOME=tmp), capture_output=True, text=True)
        assert (p.returncode == 0) == ok, p.stderr
        return p
    run('--check', ok=False)  # Existing nonempty HTML was insufficient.
    run('--option','approval','yes','Aprobar','--option','approval','research','Pedir más investigación')
    run('--check')
    first = report.read_text()
    parser = Links(); parser.feed(first)
    queries = [parse_qs(urlsplit(url).query) for url in parser.urls]
    assert len(queries) == 4
    assert queries[0] == dict(task=['task'],view=['delivery'],item=['version & one'],do=['reviewed'])
    assert queries[1] == dict(task=['approval'],view=['call'],option=['yes'])
    assert queries[2] == dict(task=['approval'],view=['call'],option=['research'])
    assert queries[3]['do'] == ['lavish']
    assert all(url.startswith('https://deck.example/base/?') for url in parser.urls)
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
    assert batch.forms == [dict(action='https://deck.example/base/', method='get')]
    assert {x['name']:x['value'] for x in batch.fields} == dict(task='task',view='delivery',item='version & one',do='decisions')
    assert [x['name'] for x in batch.choices] == ['r.approval','r.cleanup']
    choices = ('--question','approval','¿Aprobar el plan?', '--question','cleanup','¿Qué hacemos con los datos?',
               '--option','approval','yes','Aprobar', '--option','cleanup','research','Pedir más investigación')
    run('--check', *choices)
    generated = report.read_text()
    report.write_text(generated.replace('value="research"', 'value="other"'))
    run('--check', *choices, ok=False)
    report.write_text(generated.replace('<select name="r.cleanup"', '<select hidden name="r.cleanup"'))
    run('--check', *choices, ok=False)
    report.write_text(generated)
    run('--deck','javascript:alert(1)',ok=False)
    run('--deck','')
    run('--check','--deck','')  # Unconfigured home has an explicit manual fallback.
    assert 'Firstmate' in report.read_text()
print('PASS: missing, visible, stale and hidden actions; encoded decisions; idempotence; manual fallback')
PY
