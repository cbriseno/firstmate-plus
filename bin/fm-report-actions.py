#!/usr/bin/env python3
"""Attach visible report actions using the existing Deck navigation protocol.

Usage: fm-report-actions.py REPORT --task ID [--deck URL] [--occurrence ID]
       [--language LANG] [--option CALL OPTION LABEL ...] [--question CALL LABEL ...] [--check]
Defaults come from FM_HOME/config/deck-url and data/ID/presentation.json.
If no address is configured, use the Deck address supplied in the task brief.
Language follows --language, HTML lang, FM_LANGUAGE, config/language, then English.
--language records the language in HTML; the caller must write the report in it.
Publish outcome.review=needed first; use its occurrence for this HTML version.
Each --option names an existing captain call and one of its offered options.
Use --question for each call to render one selection per row and a single Send.
Without --question, options remain individual approval/decision links.
Links and forms only navigate; the Deck confirms through its existing controls.
Every Deck link and form opens in a new tab (target=_blank): Lavish shows the
report in a sandboxed iframe, and the Deck refuses framed navigations (403 on
Sec-Fetch-Dest: iframe, frame-ancestors 'none'), so only a top-level tab works.
--check also refuses any visible link or form to the Deck without target=_blank.
When a route is available without config/deck-url, pass it with --deck.
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
from urllib.parse import parse_qs, unquote, urlencode, urlsplit


class Actions(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack = []
        self.links = []
        self.targets = []
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
            self.targets.append(attrs.get('target'))
        if tag == 'form' and not hidden:
            self.form = dict(url=urlsplit(attrs.get('action', '')), method=attrs.get('method', '').lower(),
                             fields={}, options=set(), target=attrs.get('target'))
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
    parser.add_argument('--language', help='report language (defaults to HTML lang, then installation language)')
    parser.add_argument('--occurrence')
    parser.add_argument('--option', nargs=3, action='append', default=[], metavar=('CALL', 'OPTION', 'LABEL'))
    parser.add_argument('--question', nargs=2, action='append', default=[], metavar=('CALL', 'LABEL'))
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    home = Path(os.environ.get('FM_HOME', Path(__file__).resolve().parent.parent))
    deck_file = Path(os.environ.get('FM_CONFIG_OVERRIDE', home / 'config')) / 'deck-url'
    data = Path(os.environ.get('FM_DATA_OVERRIDE', home / 'data'))
    deck = args.deck if args.deck is not None else deck_file.read_text().strip() if deck_file.is_file() else ''
    if not deck and args.deck is None and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', args.task) and args.task not in ('.', '..'):
        for name in ('launch-brief.md', 'brief.md'):
            brief = data / args.task / name
            if brief.is_file():
                match = re.search(r'^Deck address for report links: (\S+)\s*$', brief.read_text(), re.M)
                if match:
                    deck = match.group(1)
                    break
    if deck and (urlsplit(deck).scheme not in ('http', 'https') or not urlsplit(deck).netloc
                 or urlsplit(deck).query or urlsplit(deck).fragment):
        parser.error('Deck address must be an absolute HTTP(S) URL without query or fragment')
    occurrence = args.occurrence
    declaration = data / args.task / 'presentation.json'
    if not occurrence and declaration.is_file():
        occurrence = json.loads(declaration.read_text()).get('outcome_occurrence')
    questions = dict(args.question)
    if questions and set(questions) != {call for call, _, _ in args.option}:
        parser.error('supply a question and offered options for every decision row')
    text = args.report.read_text()
    html_lang = re.search(r'<html\b[^>]*?\s+lang\s*=\s*[\"\']([^\"\']+)', text, re.I)
    language_file = Path(os.environ.get('FM_CONFIG_OVERRIDE', home / 'config')) / 'language'
    installed_language = language_file.read_text().strip() if language_file.is_file() else ''
    language = (args.language or (html_lang.group(1) if html_lang else None)
                or os.environ.get('FM_LANGUAGE') or installed_language or 'en')
    spanish = language.lower().split('-')[0].split('_')[0] == 'es'
    labels = ({'reviewed': 'Revisado', 'lavish': 'Abrir en Lavish para discutir',
               'note': 'El Deck confirma tu acción. Revisado no aprueba decisiones.',
               'empty': 'Sin elegir', 'send': 'Enviar', 'aria': 'Acciones del informe',
               'no_decision': 'No hay ninguna decisión pendiente.'} if spanish else
              {'reviewed': 'Reviewed', 'lavish': 'Open in Lavish to discuss',
               'note': 'Deck confirms your action. Reviewed does not approve decisions.',
               'empty': 'No selection', 'send': 'Send', 'aria': 'Report actions',
               'no_decision': 'No decision is needed.'})
    # Reports are framed by Lavish, so sibling report links must not resolve
    # against the session URL. Only rewrite task report paths under the configured data directory.
    data = Path(os.environ.get('FM_DATA_OVERRIDE', home / 'data')).resolve()
    def report_link(tag):
        href = re.search(r"(?<![\w-])href\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))", tag, re.I | re.S)
        if not href:
            return tag
        value = urlsplit(html.unescape(next(part for part in href.groups() if part is not None)))
        if value.scheme or value.netloc or value.query or value.fragment or value.path.startswith('/'):
            return tag
        target = (args.report.resolve().parent / unquote(value.path)).resolve()
        try:
            parts = target.relative_to(data).parts
        except ValueError:
            return tag
        if len(parts) != 2 or parts[1] != 'report.html' or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,127}', parts[0]):
            return tag
        destination = deck.rstrip('/') + '/?' + urlencode(dict(task=parts[0], view='delivery')) if deck else str(target)
        tag = tag[:href.start()] + 'href="' + html.escape(destination, quote=True) + '"' + tag[href.end():]
        if deck:
            tag = re.sub(r"\s+target\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)", '', tag, flags=re.I | re.S)
            if not re.search(r'(?<![\w-])rel\s*=', tag, re.I):
                tag = tag[:-1] + ' rel="noopener">'
            tag = tag[:-1] + ' target="_blank">'
        return tag
    if not args.check:
        class ReportLinks(HTMLParser):
            def __init__(self, source):
                super().__init__()
                self.offsets = [0]
                for line in source.splitlines(keepends=True):
                    self.offsets.append(self.offsets[-1] + len(line))
                self.edits = []

            def handle_starttag(self, tag, attrs):
                if tag == 'a':
                    raw = self.get_starttag_text()
                    line, column = self.getpos()
                    start = self.offsets[line - 1] + column
                    self.edits.append((start, start + len(raw), report_link(raw)))

        parser_links = ReportLinks(text)
        parser_links.feed(text)
        for start, end, replacement in reversed(parser_links.edits):
            text = text[:start] + replacement + text[end:]
    if args.check:
        if not deck:
            print('WARNING: Deck address missing; arrange report review through Firstmate.')
            return
        if args.language and (not html_lang or html_lang.group(1).lower() != language.lower()):
            parser.error('report language does not match --language')
        actions = Actions()
        actions.feed(text)
        links = [parse_qs(url.query) for url in actions.links
                 if (url.scheme, url.netloc, url.path) == (urlsplit(deck).scheme, urlsplit(deck).netloc, urlsplit(deck).path.rstrip('/') + '/')]
        deck_origin = urlsplit(deck)[:2]
        framed = [url.geturl() for url, target in zip(actions.links, actions.targets)
                  if url[:2] == deck_origin and target != '_blank']
        framed += [f['url'].geturl() for f in actions.forms if f['url'][:2] == deck_origin and f['target'] != '_blank']
        if framed:
            parser.error('Deck links and forms must open outside the Lavish frame (target="_blank"): ' + framed[0])
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
        return '<a href="' + html.escape(url, quote=True) + '" target="_blank" rel="noopener">' + html.escape(label) + '</a>'

    if deck:
        links = [link(labels['reviewed'], task=args.task, view='delivery', item=occurrence, do='reviewed')]
        if not questions:
            links.extend(link(label, task=call, view='call', option=option)
                         for call, option, label in args.option)
        links.append(link(labels['lavish'], task=args.task, view='delivery', item=occurrence, do='lavish'))
        content = '\n'.join(links) + '<small>' + labels['note']
        if not args.option:
            content += ' ' + labels['no_decision']
        content += '</small>'
        if questions:
            fields = dict(task=args.task, view='delivery', item=occurrence, do='decisions')
            rows = []
            for call, question in questions.items():
                options = '<option value="">' + labels['empty'] + '</option>' + ''.join(
                    '<option value="' + html.escape(option, quote=True) + '">' + html.escape(label) + '</option>'
                    for offered_call, option, label in args.option if offered_call == call)
                rows.append('<label>' + html.escape(question) + '<select name="r.' + html.escape(call, quote=True)
                            + '">' + options + '</select></label>')
            content += '<form action="' + html.escape(deck.rstrip('/') + '/', quote=True) + '" method="get" target="_blank">'
            content += ''.join('<input type="hidden" name="' + name + '" value="' + html.escape(value, quote=True) + '">'
                               for name, value in fields.items())
            content += ''.join(rows) + '<button type="submit">' + labels['send'] + '</button></form>'

    else:
        content = ('<p>Para marcar revisado, aprobar, pedir más investigación o discutir en Lavish, pide a Firstmate que organice la revisión.</p>' if spanish else '<p>Ask Firstmate to arrange review, approval, further investigation or discussion in Lavish.</p>')
        if not args.option:
            content += '<p>' + labels['no_decision'] + '</p>'
    if args.language or not html_lang:
        # Persist the report language so a later regeneration and the
        # browser checker use the same language as these actions.
        if html_lang:
            text = text[:html_lang.start(1)] + html.escape(language, quote=True) + text[html_lang.end(1):]
        else:
            text, count = re.subn(r'<html\b', lambda m: m.group(0) + ' lang="' + html.escape(language, quote=True) + '"', text, count=1, flags=re.I)
            if not count:
                text = '<html lang="' + html.escape(language, quote=True) + '">' + text + '</html>'
    nav = '<nav class="report-actions" aria-label="' + labels['aria'] + '">' + content + '</nav>'
    pattern = r'''<(nav|details)\b(?=[^>]*\bclass\s*=\s*(["'])[^"']*\breport-actions\b[^"']*\2)[^>]*>.*?</\1\s*>'''
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
