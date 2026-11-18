#!/usr/bin/env python3
"""Attach visible report actions using the existing Deck navigation protocol.

Usage: fm-report-actions.py REPORT --task ID [--deck URL] [--occurrence ID]
       [--option CALL OPTION LABEL ...] [--question CALL LABEL ...] [--check]
Defaults come from FM_HOME/config/deck-url and data/ID/presentation.json.
Publish outcome.review=needed first; use its occurrence for this HTML version.
Each --option names an existing captain call and one of its offered options.
Use --question for each call to render one selection per row and a single Send.
Without --question, options remain individual approval/decision links.
Links and forms only navigate; the Deck confirms through its existing controls.
Without a Deck address, render an explicit Firstmate review fallback.
--check verifies visible review navigation and the supplied choices before
delivery; repeat the generation arguments. It never writes or creates calls.
"""
import argparse
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
from urllib.parse import parse_qs, urlencode, urlsplit


class Actions(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack = []
        self.links = []
        self.forms = []
        self.form = None
        self.call = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        hidden = (any(flag for _, flag in self.stack) or tag in ('details', 'template', 'script', 'style')
                  or 'hidden' in attrs or re.search(r'(display\s*:\s*none|visibility\s*:\s*hidden)', attrs.get('style', '')))
        if tag not in ('area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr'):
            self.stack.append((tag, bool(hidden)))
        if tag == 'a' and not hidden:
            self.links.append(urlsplit(attrs.get('href', '')))
        if tag == 'form' and not hidden:
            self.form = dict(url=urlsplit(attrs.get('action', '')), method=attrs.get('method', '').lower(),
                             fields={}, options=set())
            self.forms.append(self.form)
        if self.form is not None:
            if tag == 'input':
                self.form['fields'][attrs.get('name')] = attrs.get('value')
            if tag == 'select':
                self.call = attrs.get('name', '')[2:] if not hidden and attrs.get('name', '').startswith('r.') else None
            if tag == 'option' and not hidden and self.call:
                self.form['options'].add((self.call, attrs.get('value')))

    def handle_endtag(self, tag):
        if tag == 'form':
            self.form = None
        if tag == 'select':
            self.call = None
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('report', type=Path)
    parser.add_argument('--task', required=True)
    parser.add_argument('--deck')
    parser.add_argument('--occurrence')
    parser.add_argument('--option', nargs=3, action='append', default=[], metavar=('CALL', 'OPTION', 'LABEL'))
    parser.add_argument('--question', nargs=2, action='append', default=[], metavar=('CALL', 'LABEL'))
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    home = Path(os.environ.get('FM_HOME', Path(__file__).resolve().parent.parent))
    deck_file = Path(os.environ.get('FM_CONFIG_OVERRIDE', home / 'config')) / 'deck-url'
    deck = args.deck if args.deck is not None else deck_file.read_text().strip() if deck_file.is_file() else ''
    if deck and (urlsplit(deck).scheme not in ('http', 'https') or not urlsplit(deck).netloc
                 or urlsplit(deck).query or urlsplit(deck).fragment):
        parser.error('Deck address must be an absolute HTTP(S) URL without query or fragment')
    occurrence = args.occurrence
    declaration = Path(os.environ.get('FM_DATA_OVERRIDE', home / 'data')) / args.task / 'presentation.json'
    if not occurrence and declaration.is_file():
        occurrence = json.loads(declaration.read_text()).get('outcome_occurrence')
    questions = dict(args.question)
    if questions and set(questions) != {call for call, _, _ in args.option}:
        parser.error('supply a question and offered options for every decision row')
    text = args.report.read_text()
    if args.check:
        actions = Actions()
        actions.feed(text)
        if not deck:
            # A home with no destination cannot promise working remote buttons.
            print('WARNING: Deck address missing; arrange report review through Firstmate.')
            return
        links = [parse_qs(url.query) for url in actions.links
                 if (url.scheme, url.netloc, url.path) == (urlsplit(deck).scheme, urlsplit(deck).netloc, urlsplit(deck).path.rstrip('/') + '/')]
        for action in ('reviewed', 'lavish'):
            if not any(link.get('task') == [args.task] and link.get('view') == ['delivery']
                       and link.get('item') == [occurrence] and link.get('do') == [action]
                       for link in links) or not occurrence:
                parser.error('report requires visible Reviewed and Lavish links for its published occurrence; '
                             'run fm-report-actions.py before delivery')
        for call, option, _ in args.option:
            direct = any(q.get('task') == [call] and q.get('view') == ['call']
                         and q.get('option') == [option] for q in links)
            row = any(f['method'] == 'get' and f['url'] == urlsplit(deck.rstrip('/') + '/')
                      and f['fields'] == dict(task=args.task, view='delivery', item=occurrence, do='decisions')
                      and (call, option) in f['options'] for f in actions.forms)
            if not (row if questions else direct):
                parser.error('report is missing a requested visible choice: ' + call + '/' + option)
        print('OK: visible Reviewed and Lavish actions match the published report occurrence')
        return
    if deck and not occurrence:
        parser.error('publish outcome.review=needed first or supply --occurrence')

    def link(label, **query):
        url = deck.rstrip('/') + '/?' + urlencode(query)
        return '<a href="' + html.escape(url, quote=True) + '">' + html.escape(label) + '</a>'

    if deck:
        links = [link('Revisado', task=args.task, view='delivery', item=occurrence, do='reviewed')]
        if not questions:
            links.extend(link(label, task=call, view='call', option=option)
                         for call, option, label in args.option)
        links.append(link('Abrir en Lavish para discutir', task=args.task, view='delivery', item=occurrence, do='lavish'))
        content = '\n'.join(links) + '<small>El Deck confirma tu acción. Revisado no aprueba decisiones.</small>'
        if questions:
            fields = dict(task=args.task, view='delivery', item=occurrence, do='decisions')
            rows = []
            for call, question in questions.items():
                options = '<option value="">Sin elegir</option>' + ''.join(
                    '<option value="' + html.escape(option, quote=True) + '">' + html.escape(label) + '</option>'
                    for offered_call, option, label in args.option if offered_call == call)
                rows.append('<label>' + html.escape(question) + '<select name="r.' + html.escape(call, quote=True)
                            + '">' + options + '</select></label>')
            content += '<form action="' + html.escape(deck.rstrip('/') + '/', quote=True) + '" method="get">'
            content += ''.join('<input type="hidden" name="' + name + '" value="' + html.escape(value, quote=True) + '">'
                               for name, value in fields.items())
            content += ''.join(rows) + '<button type="submit">Enviar</button></form>'

    else:
        content = '<p>Para marcar revisado, aprobar, pedir más investigación o discutir en Lavish, pide a Firstmate que organice la revisión.</p>'
    nav = '<nav class="report-actions" aria-label="Acciones del informe">' + content + '</nav>'
    pattern = r'<(nav|details)\b[^>]*class="report-actions"[^>]*>.*?</\1>'
    if re.search(pattern, text, flags=re.S):
        text = re.sub(pattern, lambda _: nav, text, count=1, flags=re.S)
    elif '</header>' in text:
        text = text.replace('</header>', nav + '\n</header>', 1)
    elif '</body>' in text:
        text = text.replace('</body>', nav + '\n</body>', 1)
    else:
        parser.error('report needs a closing header or body for its actions')
    args.report.write_text(text)


if __name__ == '__main__':
    main()
