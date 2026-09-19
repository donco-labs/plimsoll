#!/usr/bin/env python3
"""Build a self-contained, print-optimised HTML copy of an article.

    python3 docs/assets/build-print.py docs/article-itnext.md

Figures are substituted for the *(Figure N ...)* placeholder paragraphs and
embedded as base64, so the output is one file with no network requests.
"""
import pathlib, re, html, base64, sys

HERE  = pathlib.Path(__file__).parent
args  = [a for a in sys.argv[1:] if not a.startswith('--')]
src   = pathlib.Path(args[0] if args else HERE.parent / 'article-itnext.md')
md    = src.read_text()

# US Letter is 216x279mm against A4's 210x297: wider column, ~1cm less height per
# page, so the two paginate differently and each needs its own render.
PAPER  = 'Letter' if '--letter' in sys.argv else 'A4'
SUFFIX = '-letter' if PAPER == 'Letter' else ''

FIGS = {
    '1': ('fig-chain.png',
          'Six-step diagram running from a disk passing 90 percent full, through lost '
          'headroom and saturated memory, to page-cache eviction, sustained re-reads at '
          '18 MB/s, and kernel stalls with watchdog timeouts.'),
    '2': ('fig-ratio.png',
          'Bar chart comparing 39.5 TB read against 13.8 TB written over 438 powered-on '
          'hours, roughly 90 GB per hour.'),
    '3': ('fig-inversion.png',
          'Two ranked bar charts showing four directories reordering completely between a '
          'ranking by size and a ranking by file count.'),
    '4': ('fig-timeline.png',
          'Timeline of completed backups during 2026, ending on 6 July, followed by a '
          '62-day gap with no completed backup.'),
    '5': ('fig-scoreboard.png',
          'Four before-and-after tiles: free space, swap available, last backup age and '
          'backup duration.'),
}
_cache = {}
def figure(num, caption):
    name, alt = FIGS[num]
    if name not in _cache:
        _cache[name] = base64.b64encode((HERE / name).read_bytes()).decode()
    return (f'<figure><img alt="{html.escape(alt)}" src="data:image/png;base64,{_cache[name]}">'
            f'<figcaption>{html.escape(caption)}</figcaption></figure>')

def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', t)
    t = re.sub(r'(?<!\*)\*([^*\n]+)\*(?!\*)', r'<em>\1</em>', t)
    t = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', t)
    return t

lines, out, i, n = md.split('\n'), [], 0, len(md.split('\n'))
title = subtitle = ''
while i < n:
    L = lines[i]
    if L.startswith('```'):
        buf = []; i += 1
        while i < n and not lines[i].startswith('```'):
            buf.append(html.escape(lines[i])); i += 1
        out.append('<pre><code>' + '\n'.join(buf) + '</code></pre>'); i += 1
    elif L.startswith('|'):
        rows = []
        while i < n and lines[i].startswith('|'): rows.append(lines[i]); i += 1
        cells = [[c.strip() for c in r.strip('|').split('|')]
                 for r in rows if not set(r) <= set('|-: ')]
        head = ''.join(f'<th>{inline(c)}</th>' for c in cells[0])
        body = ''.join('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>'
                       for r in cells[1:])
        out.append(f'<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>')
    elif L.startswith('## '):
        out.append(f'<h2>{inline(L[3:])}</h2>'); i += 1
    elif L.startswith('# '):
        title = L[2:].strip(); i += 1
    elif L.strip() == '':
        i += 1
    else:
        buf = [lines[i].strip()]; i += 1   # always consume one, or a paragraph
        while i < n and lines[i].strip() and lines[i][:1] not in '#|`':   # opening with
            buf.append(lines[i].strip()); i += 1                          # `code` loops
        para = ' '.join(buf)
        m = re.match(r'^\*\((Figure (\d).*?)\)\*$', para)
        if m:
            out.append(figure(m.group(2), m.group(1).replace(', goes here as the cover image', '')
                                                    .replace(', goes here', '')
                                                    .replace(', repeated here', '')))
        elif not subtitle and para.startswith('*') and para.endswith('*'):
            subtitle = para.strip('*')
        else:
            out.append(f'<p>{inline(para)}</p>')

doc = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>{html.escape(title)}</title>
<style>
  @page {{ size: {PAPER}; margin: 18mm 16mm 20mm; }}
  html {{ -webkit-print-color-adjust: exact; print-color-adjust: exact; }}
  body {{ font: 11.5pt/1.55 Charter, "Iowan Old Style", Georgia, serif;
         color: #1a1a1a; background: #fff; max-width: 42em; margin: 2rem auto; padding: 0 1.5rem; }}
  h1 {{ font-size: 1.9em; line-height: 1.2; margin: 0 0 .4em; }}
  .sub {{ font-style: italic; color: #444; margin: 0 0 2em; font-size: 1.05em; }}
  h2 {{ font-size: 1.18em; margin: 2.1em 0 .6em; page-break-after: avoid; break-after: avoid; }}
  p {{ margin: 0 0 1em; orphans: 3; widows: 3; }}
  code {{ font-family: "SF Mono", Menlo, Consolas, monospace; font-size: .86em;
          background: #f2f2ef; padding: .1em .3em; border-radius: 3px; }}
  pre {{ background: #f7f7f4; border: 1px solid #e2e2dc; border-left: 3px solid #b9b9ae;
         padding: .8em 1em; margin: 1.2em 0; page-break-inside: avoid; break-inside: avoid; }}
  pre code {{ background: none; padding: 0; font-size: .8em; line-height: 1.45;
              white-space: pre-wrap; overflow-wrap: break-word; }}
  table {{ border-collapse: collapse; width: 100%; margin: 1.2em 0; font-size: .9em;
           page-break-inside: avoid; break-inside: avoid; }}
  th, td {{ border-bottom: 1px solid #ddd; padding: .45em .6em; text-align: left; }}
  th {{ border-bottom: 1.5px solid #999; }}
  figure {{ margin: 1.6em 0; page-break-inside: avoid; break-inside: avoid; }}
  figure img {{ width: 100%; height: auto; border: 1px solid #e2e2dc; }}
  figcaption {{ font-size: .82em; color: #555; margin-top: .5em; font-style: italic; }}
  a {{ color: #1a1a1a; text-decoration: underline; text-decoration-color: #aaa; }}
  @media print {{
    body {{ margin: 0; padding: 0; max-width: none; }}
    a[href^="http"]::after {{ content: " (" attr(href) ")"; font-size: .8em; color: #666;
                              word-break: break-all; }}
  }}
</style></head><body>
<h1>{html.escape(title)}</h1>
<p class="sub">{inline(subtitle)}</p>
{chr(10).join(out)}
</body></html>"""

dest = src.with_name(src.stem + SUFFIX + '.html')
dest.write_text(doc)
print(f'{dest}  {len(doc)/1024:.0f} KB  ({len(_cache)} figures embedded)')

# Safari's File > Export as PDF emits one continuous page, ignoring @page; only
# File > Print paginates.  Rendering here takes the browser out of the loop.
if '--pdf' in sys.argv:
    import subprocess
    chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
    pdf = dest.with_suffix('.pdf')
    subprocess.run([chrome, '--headless', '--disable-gpu', '--no-pdf-header-footer',
                    f'--print-to-pdf={pdf.resolve()}', dest.resolve().as_uri()],
                   check=True, capture_output=True)
    print(f'{pdf}  {pdf.stat().st_size/1024:.0f} KB')
