"""Minimal, dependency-free Markdown -> HTML converter.

Covers exactly the subset this repository's documentation uses: ATX headings, fenced code
blocks, pipe tables, nested ordered/unordered lists (with task checkboxes), blockquotes,
horizontal rules, inline code, bold/italic/strikethrough, links and images.

Deliberately NOT CommonMark. Unsupported syntax degrades to plain paragraphs instead of
raising, and the build script asserts the structural counts (fences, tables) so a silent
degradation is caught at build time rather than noticed in the browser.
"""

from __future__ import annotations

import html
import re

_FENCE = re.compile(r"^(\s*)```([A-Za-z0-9_+\-.#]*)\s*$")
_HEAD = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
_HR = re.compile(r"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$")
_UL = re.compile(r"^(\s*)([-*+])\s+(.*)$")
_OL = re.compile(r"^(\s*)(\d+)[.)]\s+(.*)$")
_QUOTE = re.compile(r"^\s*>\s?(.*)$")
_TABLE_CELL_SEP = r"(?:\s*:?-{2,}:?\s*)$"

SLUG_RE = re.compile(r"[^a-z0-9]+")


def slugify(text: str) -> str:
    return SLUG_RE.sub("-", text.lower()).strip("-") or "section"


def inline(text: str, resolver=None) -> str:
    """Inline markup. Code spans are stashed first so their contents are never reinterpreted."""
    stash: list[str] = []

    def put_code(m: "re.Match[str]") -> str:
        stash.append(m.group(1))
        return "\x00%d\x00" % (len(stash) - 1)

    text = re.sub(r"`([^`]+)`", put_code, text)
    text = html.escape(text, quote=False)

    def link(m: "re.Match[str]") -> str:
        label, href = m.group(1), m.group(2)
        href = href.replace("&amp;", "&")
        if resolver is not None:
            resolved = resolver(href)
            if resolved is None:
                # The resolver knows this is a local path that is NOT embedded in the output
                # (a raw artefact outside files/, a script, the PCI dump). Rendering it as a
                # dead <a href> would be a lie; render it as inert text with an explanation.
                return ('<span class="nolit" title="in the repository, not embedded in this page: %s">%s</span>'
                        % (html.escape(href, quote=True), label))
            href = resolved
        return '<a href="%s">%s</a>' % (html.escape(href, quote=True), label)

    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)", link, text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"~~(.+?)~~", r"<del>\1</del>", text)

    def restore(m: "re.Match[str]") -> str:
        return "<code>%s</code>" % html.escape(stash[int(m.group(1))], quote=False)

    return re.sub(r"\x00(\d+)\x00", restore, text)


def _split_row(row: str) -> list[str]:
    """Split a table row on pipes, ignoring pipes inside backtick spans."""
    s = row.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    cells, buf, in_code = [], [], False
    for ch in s:
        if ch == "`":
            in_code = not in_code
            buf.append(ch)
        elif ch == "|" and not in_code:
            cells.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    cells.append("".join(buf))
    return [c.strip() for c in cells]


def _is_table_start(lines: list[str], i: int) -> bool:
    if i + 1 >= len(lines) or "|" not in lines[i]:
        return False
    sep = _split_row(lines[i + 1])
    if not sep:
        return False
    return all(re.fullmatch(r":?-{2,}:?", c or "") for c in sep) and "-" in lines[i + 1]


def _render_table(lines: list[str], i: int, resolver) -> tuple[str, int]:
    header = _split_row(lines[i])
    aligns = []
    for cell in _split_row(lines[i + 1]):
        left, right = cell.startswith(":"), cell.endswith(":")
        aligns.append("center" if left and right else "right" if right else "left")
    out = ['<div class="tw"><table><thead><tr>']
    for n, cell in enumerate(header):
        out.append('<th style="text-align:%s">%s</th>' % (aligns[n] if n < len(aligns) else "left", inline(cell, resolver)))
    out.append("</tr></thead><tbody>")
    i += 2
    while i < len(lines) and lines[i].strip() and "|" in lines[i]:
        cells = _split_row(lines[i])
        out.append("<tr>")
        for n in range(len(header)):
            cell = cells[n] if n < len(cells) else ""
            out.append('<td style="text-align:%s">%s</td>' % (aligns[n] if n < len(aligns) else "left", inline(cell, resolver)))
        out.append("</tr>")
        i += 1
    out.append("</tbody></table></div>")
    return "\n".join(out), i


def _render_list(lines: list[str], i: int, resolver) -> tuple[str, int]:
    block: list[str] = []
    while i < len(lines):
        line = lines[i]
        if _UL.match(line) or _OL.match(line):
            block.append(line)
            i += 1
            continue
        if line.strip() == "" and i + 1 < len(lines) and (_UL.match(lines[i + 1]) or _OL.match(lines[i + 1])):
            block.append("")
            i += 1
            continue
        if line.startswith(("  ", "\t")) and line.strip():
            block.append(line)
            i += 1
            continue
        break

    out: list[str] = []
    stack: list[list] = []          # [indent, tag, li_open]
    last_li: int | None = None

    def close_list() -> None:
        nonlocal last_li
        indent, tag, li_open = stack.pop()
        if li_open:
            out.append("</li>")
        out.append("</%s>" % tag)
        last_li = None

    for raw in block:
        if raw.strip() == "":
            continue
        mu, mo = _UL.match(raw), _OL.match(raw)
        m = mu or mo
        if not m:
            if last_li is not None:
                out[last_li] = out[last_li].removesuffix("</li>") + " " + inline(raw.strip(), resolver) + "</li>"
            else:
                out.append("<p>%s</p>" % inline(raw.strip(), resolver))
            continue
        indent = len(m.group(1))
        ordered = mo is not None
        tag = "ol" if ordered else "ul"
        text = m.group(3)

        while stack and stack[-1][0] > indent:
            close_list()
        if stack and stack[-1][0] == indent:
            if stack[-1][1] != tag:
                close_list()
                out.append("<%s>" % tag)
                stack.append([indent, tag, False])
            elif stack[-1][2]:
                out.append("</li>")
                stack[-1][2] = False
        else:
            # A deeper list becomes a child of the still-open parent <li>: valid nesting.
            out.append("<%s>" % tag)
            stack.append([indent, tag, False])

        prefix = ""
        if text.startswith("[ ] "):
            prefix, text = '<span class="cb">☐</span> ', text[4:]
        elif text.lower().startswith("[x] "):
            prefix, text = '<span class="cb done">☑</span> ', text[4:]
        out.append("<li>%s%s</li>" % (prefix, inline(text, resolver)))
        last_li = len(out) - 1
        stack[-1][2] = True

    while stack:
        close_list()
    return "\n".join(out), i


def to_html(md: str, resolver=None, heading_ids: list[tuple[int, str, str]] | None = None) -> str:
    """Convert `md` to HTML. `heading_ids`, if given, is filled with (level, id, text)."""
    lines = md.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]

        m = _FENCE.match(line)
        if m:
            indent, lang = len(m.group(1)), m.group(2)
            i += 1
            body: list[str] = []
            while i < len(lines) and not re.match(r"^\s*```\s*$", lines[i]):
                body.append(lines[i][min(indent, len(lines[i]) - len(lines[i].lstrip())):])
                i += 1
            i += 1
            cls = ' class="lang-%s"' % lang if lang else ""
            out.append('<div class="cb-wrap"><pre class="code"%s><code>%s</code></pre></div>'
                       % (cls, html.escape("\n".join(body), quote=False)))
            continue

        if not line.strip():
            i += 1
            continue

        m = _HEAD.match(line)
        if m:
            level = len(m.group(1))
            text = m.group(2)
            hid = slugify(re.sub(r"[`*]", "", text))
            if heading_ids is not None:
                used = {h[1] for h in heading_ids}
                base, n = hid, 2
                while hid in used:
                    hid = "%s-%d" % (base, n)
                    n += 1
                heading_ids.append((level, hid, re.sub(r"[`*]", "", text)))
            out.append('<h%d id="%s">%s<a class="anchor" href="#%s" aria-label="link">#</a></h%d>'
                       % (level, hid, inline(text, resolver), hid, level))
            i += 1
            continue

        if _is_table_start(lines, i):
            html_table, i = _render_table(lines, i, resolver)
            out.append(html_table)
            continue

        if _UL.match(line) or _OL.match(line):
            html_list, i = _render_list(lines, i, resolver)
            out.append(html_list)
            continue

        if _QUOTE.match(line):
            body = []
            while i < len(lines) and _QUOTE.match(lines[i]):
                body.append(_QUOTE.match(lines[i]).group(1))
                i += 1
            out.append("<blockquote>%s</blockquote>" % to_html("\n".join(body), resolver))
            continue

        if _HR.match(line):
            out.append("<hr>")
            i += 1
            continue

        para = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not (
            _HEAD.match(lines[i]) or _FENCE.match(lines[i]) or _HR.match(lines[i])
            or _UL.match(lines[i]) or _OL.match(lines[i]) or _QUOTE.match(lines[i])
            or _is_table_start(lines, i)
        ):
            para.append(lines[i].strip())
            i += 1
        out.append("<p>%s</p>" % inline(" ".join(para), resolver))

    return "\n".join(out)


def count_fences(md: str) -> int:
    """Number of fenced code BLOCKS (an opening fence with a language, or an unclosed one).

    Counting every ``` line would double-count each block, since the closing fence matches too.
    """
    count, inside, pending = 0, False, False
    for line in md.split("\n"):
        # Blockquoted fences ('> ```bash') are real blocks too: the converter recurses into
        # blockquote content, so the counter must look through the same prefix.
        m = _FENCE.match(re.sub(r"^(\s*>\s?)+", "", line))
        if not inside:
            if m:
                inside, pending = True, not m.group(2)   # bare ``` opens an anonymous block
                count += 1
        else:
            if m and not m.group(2):                    # a bare ``` closes
                inside, pending = False, False
            elif m and m.group(2):                      # a language fence inside a block
                if pending:
                    pending = False                     # that was the real opening
                else:
                    inside = False                      # unterminated: treat as closing
    return count


def count_tables(md: str) -> int:
    lines = md.split("\n")
    return sum(1 for i in range(len(lines)) if _is_table_start(lines, i))
