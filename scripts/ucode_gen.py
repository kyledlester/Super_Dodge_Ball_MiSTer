#!/usr/bin/env python3
# Super Dodge Ball MiSTer core -- microcode generator for the jt680x CPU family.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Python port of jtframe's `jtframe ucode` command (jotego/jtcores modules/jtframe/src/jtframe/ucode/
# ucode.go, GPL-3.0-or-later, Jose Tejada). The jt65c02 / jt680x RTL includes <out>.vh and
# <out>_param.vh and loads <out>.uc; jtcores generates them at build time with a Go tool. This port
# produces the same three files so the vendored RTL builds without a Go toolchain. The YAML reader
# covers the subset the jt680x ucode files use (block maps/sequences, one-line flow maps/lists,
# comments, multi-line plain scalars, empty sequence items = "").
#
# usage: python scripts/ucode_gen.py <ucode dir> <src.yaml> <out dir> [output name]
import math
import os
import re
import sys

# ---------------------------------------------------------------------------- YAML subset


def _strip_comment(s):
    out, depth = [], 0
    for i, ch in enumerate(s):
        if ch == '#' and (i == 0 or s[i - 1] in ' \t'):
            break
        out.append(ch)
    return ''.join(out).rstrip()


def _split_flow(s):
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch in '{[':
            depth += 1
        elif ch in '}]':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(''.join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if ''.join(cur).strip():
        parts.append(''.join(cur).strip())
    return parts


def _flow(s):
    s = s.strip()
    if s.startswith('{'):
        d = {}
        for p in _split_flow(s[1:-1]):
            k, _, v = p.partition(':')
            d[k.strip()] = _flow(v)
        return d
    if s.startswith('['):
        return [_flow(p) for p in _split_flow(s[1:-1])]
    if len(s) >= 2 and s[0] == s[-1] and s[0] in '"\'':
        return s[1:-1]
    return s


KEY = re.compile(r'^([A-Za-z_][\w]*)\s*:(\s+|$)(.*)$')


class _Reader:
    def __init__(self, text):
        self.lines = []
        for raw in text.splitlines():
            t = _strip_comment(raw.replace('\t', '    '))
            if t.strip() == '':
                # keep "- " items that were comment-only as empty items
                if raw.strip().startswith('-'):
                    ind = len(raw) - len(raw.lstrip())
                    self.lines.append((ind, '-'))
                continue
            self.lines.append((len(t) - len(t.lstrip()), t.strip()))
        self.i = 0

    def peek(self):
        return self.lines[self.i] if self.i < len(self.lines) else (None, None)

    def scalar_cont(self, first, ind):
        # plain scalar continued on more-indented lines that are not keys or items
        parts = [first]
        while True:
            li, lt = self.peek()
            if li is None or li <= ind or lt.startswith('-') or KEY.match(lt):
                break
            parts.append(lt)
            self.i += 1
        return ' '.join(parts)

    def value(self, text, ind):
        if text.startswith('{') or text.startswith('['):
            # allow flow collections spanning lines
            while text.count('{') + text.count('[') > text.count('}') + text.count(']'):
                _, lt = self.peek()
                text += ' ' + lt
                self.i += 1
            return _flow(text)
        return _flow(self.scalar_cont(text, ind))

    def block(self, ind):
        li, lt = self.peek()
        if li is None:
            return None
        if lt == '-' or lt.startswith('- '):
            return self.seq(li)
        return self.map(li)

    def seq(self, ind):
        out = []
        while True:
            li, lt = self.peek()
            if li != ind or not (lt == '-' or lt.startswith('- ')):
                break
            rest = lt[1:].strip()
            self.i += 1
            if rest == '':
                ni, _ = self.peek()
                out.append(self.block(ni) if ni is not None and ni > ind else '')
            elif KEY.match(rest) and not rest.startswith('{'):
                # mapping whose first key shares the item line
                self.i -= 1
                self.lines[self.i] = (ind + 2, rest)
                out.append(self.map(ind + 2))
            else:
                out.append(self.value(rest, ind))
        return out

    def map(self, ind):
        out = {}
        while True:
            li, lt = self.peek()
            if li != ind:
                break
            m = KEY.match(lt)
            if not m:
                break
            k, v = m.group(1), m.group(3).strip()
            self.i += 1
            if v == '':
                ni, nt = self.peek()
                if ni is not None and (ni > ind or (ni == ind and (nt == '-' or nt.startswith('- ')))):
                    out[k] = self.block(ni)
                else:
                    out[k] = ''
            else:
                out[k] = self.value(v, ind)
        return out


def load_yaml(path):
    with open(path, encoding='utf-8') as f:
        r = _Reader(f.read())
    d = r.block(0)
    if r.i != len(r.lines):
        raise SystemExit(f'{path}: YAML subset parser stopped at line {r.lines[r.i]}')
    return d or {}


def _int(v, default=0):
    if v is None or v == '':
        return default
    return int(str(v), 0)


def _bool(v):
    return str(v).lower() == 'true'


def _str(v):
    return '' if v is None else str(v)

# ---------------------------------------------------------------------------- ucode.go port


class Op:
    def __init__(self, d):
        self.name = _str(d.get('name'))
        self.op = _int(d.get('op'))
        self.mask = _int(d.get('mask'))
        self.cycles = _int(d.get('cycles'))
        ctl = d.get('ctl') or {}
        self.ctl = {k: _str(v) for k, v in ctl.items()}

    def id(self):
        return '%-5s:0x%02x' % (self.name, self.op)


class Chunk:
    def __init__(self, d):
        seq = d.get('seq') or []
        self.seq = [_str(s) for s in seq]
        mn = d.get('mnemo') or []
        self.mnemo = [_str(m) for m in (mn if isinstance(mn, list) else [mn])]
        self.name = _str(d.get('name'))
        self.start = _int(d.get('start'))
        self.no_auto = _bool(d.get('no_auto'))
        self.cycles_spec = _int(d.get('cycles'))
        if d.get('range'):
            raise SystemExit('ucode_gen: template ranges are not supported by this port')
        self.local = None
        self.cycles = 0


class Desc:
    pass


def read_desc(path):
    y = load_yaml(path)
    d = Desc()
    cfg = y.get('config') or {}
    d.entry_len = _int(cfg.get('entry_len'))
    d.entries = _int(cfg.get('entries'))
    d.cycle_k = _int(cfg.get('cycle_factor'))
    d.implicit = _bool(cfg.get('implicit'))
    d.bus_error = _str(cfg.get('bus_error'))
    d.latch = _bool(cfg.get('latch_ucode'))
    d.ignore_cycles = _bool(cfg.get('ignore_cycles'))
    if cfg.get('auto'):
        raise SystemExit('ucode_gen: automatic procedure placement is not supported by this port')
    d.constants = {k: _str(v) for k, v in (y.get('constants') or {}).items()}
    d.ops = [Op(o) for o in (y.get('ops') or [])]
    d.chunks = [Chunk(c) for c in (y.get('ucode') or [])]
    for inc in (y.get('include') or []):
        idesc = read_desc(os.path.join(os.path.dirname(path), inc))
        if d.entry_len == 0: d.entry_len = idesc.entry_len
        if d.entries == 0: d.entries = idesc.entries
        if d.cycle_k == 0: d.cycle_k = idesc.cycle_k
        if d.bus_error == '': d.bus_error = idesc.bus_error
        if not d.implicit: d.implicit = idesc.implicit
        d.ops = idesc.ops + d.ops
        for ch in idesc.chunks:
            if ch.name != '' and find_proc(d, ch.name) < 0:
                d.chunks.append(ch)
                continue
            if any(find_chunk(d, m) != -1 for m in ch.mnemo):
                continue
            d.chunks.append(ch)
    for o in d.ops:
        for k, v in o.ctl.items():
            if v.strip() == '$':
                o.ctl[k] = k
    return d


RE_VARS = re.compile(r'\$\{([a-zA-Z][a-zA-Z0-9_]*?)\}')
RE_SP = re.compile(r' +')
RE_DIG = re.compile(r'\b[0-9]')


def find_chunk(desc, name):
    ref = -1
    for k, ch in enumerate(desc.chunks):
        if name in ch.mnemo:
            if ref != -1:
                raise SystemExit(f'Duplicated entry for mnemonic {name}')
            ref = k
    return ref


def find_proc(desc, name):
    name = name.upper()
    for k, ch in enumerate(desc.chunks):
        if ch.name.upper() == name:
            return k
    return -1


def chunk2code(desc, mnemok, up0, opk, ident, proc, code, used):
    upk = 0
    ops_ok = 0 <= opk < len(desc.ops)
    for each in desc.chunks[mnemok].seq:
        if upk >= desc.entry_len:
            raise SystemExit(f'ucode for {ident} is longer than {desc.entry_len} steps')
        tokens = each.replace(',', ' ').split()
        skip_line = False
        for k in range(len(tokens)):
            while True:
                parms = RE_VARS.findall(tokens[k])
                if not parms:
                    break
                for pname in parms:
                    val, fnd = '', False
                    if opk != -1 and ops_ok and pname in desc.ops[opk].ctl:
                        val, fnd = desc.ops[opk].ctl[pname], True
                    if not fnd and desc.chunks[mnemok].local is not None and pname in desc.chunks[mnemok].local:
                        val, fnd = desc.chunks[mnemok].local[pname], True
                    if not fnd:
                        fnd = pname in desc.constants
                        val = desc.constants.get(pname, '')
                        if not fnd and (proc or not desc.implicit):
                            raise SystemExit(f'Cannot find ucode parameter {pname} while parsing {ident}')
                    else:
                        used[pname] = True
                    tokens[k] = tokens[k].replace('${' + pname + '}', val)
            opts = tokens[k].split('?')
            if len(opts) != 1:
                if len(opts) > 2:
                    raise SystemExit(f'Multiple ? in {tokens[k]}')
                whole_line = opts[1] == '*'
                val = True
                eqs = opts[0].split('=')
                if len(eqs) == 2 and eqs[0] != eqs[1]:
                    val = False
                if len(eqs) == 1 and (opts[0] == '' or opts[0] == '0'):
                    val = False
                if whole_line:
                    if not val:
                        skip_line = True
                        break
                    tokens[k] = ''
                else:
                    evals = opts[1].split(':')
                    if val:
                        tokens[k] = evals[0]
                    elif len(evals) == 2:
                        tokens[k] = evals[1]
                    else:
                        tokens[k] = ''
            if tokens[k].startswith('_') or tokens[k].endswith('=') or tokens[k].endswith('=0'):
                tokens[k] = ''
            if tokens[k].endswith('=1'):
                tokens[k] = tokens[k][:-2]
            if RE_DIG.search(tokens[k]):
                raise SystemExit(f'Invalid signal name {tokens[k]} while parsing {ident}: {each}')
            if tokens[k].count('_') > 1:
                raise SystemExit(f'Only one _ is allowed in a signal name: {tokens[k]} ({ident})')
        if skip_line:
            continue
        if code[up0 + upk] != '':
            raise SystemExit(f'Duplicated ucode at uaddress {up0 // desc.entry_len:X},{upk:X} ({ident})')
        code[up0 + upk] = RE_SP.sub(' ', ' '.join(tokens).strip()).upper()
        upk += 1
    return upk


def expand_entry(desc, opk, mnemok, code):
    used = {}
    ch = desc.chunks[mnemok]
    if ch.name != '':
        up0, ident, proc = ch.start, ch.name, True
        if up0 < 0:
            up0 = opk
            if up0 < 0:
                return
    else:
        up0, ident, proc = desc.ops[opk].op, desc.ops[opk].id(), False
        for each in desc.ops[opk].ctl:
            used[each] = False
    up0 *= desc.entry_len
    ch.cycles = chunk2code(desc, mnemok, up0, opk, ident, proc, code, used)
    for k, v in used.items():
        if not v:
            raise SystemExit(f'Unused parameter {k} in OP {ident}')


def range_mask(entries, op, f):
    step = 1
    while step & op.mask:
        step <<= 1
    mmax = 0
    k = 0
    while (1 << k) < entries:
        if ((1 << k) & op.mask) == 0:
            mmax = k
        k += 1
    mmax += 1
    for k in range(0, 1 << mmax, step):
        f(op.op | (k & ~op.mask))


def check_duplicated(desc):
    names = set()
    for ch in desc.chunks:
        if ch.name == '':
            continue
        if ch.name in names:
            raise SystemExit(f'Duplicated ucode procedure {ch.name}')
        names.add(ch.name)
    used = [None] * desc.entries
    for op in desc.ops:
        if op.mask == 0 or op.mask >= desc.entries:
            op.mask = desc.entries - 1

        def mark(m, op=op):
            if used[m] is op:
                return
            if used[m] is not None:
                raise SystemExit(f'OP {m:X} ({op.name}) duplicated, used by {used[m].name}')
            used[m] = op
        range_mask(desc.entries, op, mark)


def expand_all(desc):
    op_dups = set()
    code = [''] * (desc.entries * desc.entry_len)
    syntax = re.compile(r'[0-1a-zA-Z][0-9a-zA-Z]*')
    for k, ch in enumerate(desc.chunks):
        if ch.name == '':
            if not ch.mnemo:
                raise SystemExit('dangling ucode chunk detected')
            continue
        expand_entry(desc, -1, k, code)
        if ch.start >= 0:
            op_dups.add(ch.start)
    missing = 0
    for opk, op in enumerate(desc.ops):
        if op.op in op_dups:
            raise SystemExit(f'Duplicated entry for op={op.op:X} ({op.name})')
        op_dups.add(op.op)
        for k, v in op.ctl.items():
            if v == '':
                continue
            if not syntax.match(k) or not syntax.match(v):
                raise SystemExit(f'Bad control signal {k}={v} in OP {op.op:X}')
        ref = find_chunk(desc, op.name)
        if ref == -1:
            print(f'Missing ucode for {op.name} (0x{op.op:x})')
            missing += 1
            continue
        expand_entry(desc, opk, ref, code)

        def copy(opnx, op=op):
            src = op.op * desc.entry_len
            op_dups.add(opnx)
            dst = opnx * desc.entry_len
            if src == dst:
                return
            for line in range(desc.entry_len):
                code[dst + line] = code[src + line]
        range_mask(desc.entries, op, copy)
    if desc.bus_error != '':
        ref = find_proc(desc, desc.bus_error)
        if ref == -1:
            print(f'Missing ucode for {desc.bus_error}')
        else:
            for k in range(desc.entries):
                if k in op_dups:
                    continue
                expand_entry(desc, k, ref, code)
    if missing:
        print(f'{missing} instructions lack ucode sequence')
    return code


RE_JSR = re.compile(r'([a-zA-Z][a-zA-Z0-9_]+)_JSR')
RE_NI = re.compile(r'\bNI|HALT\b')


def calc_cycles(uaddr, code, recurse, desc, was_ni):
    s = 0
    k = uaddr
    while k < len(code) and not was_ni[0]:
        each = code[k]
        s += 1
        if RE_NI.search(each):
            was_ni[0] = True
            break
        jsr = RE_JSR.search(each)
        if jsr:
            if jsr.group(1) == 'RET':
                break
            proc = find_proc(desc, jsr.group(1))
            if proc == -1:
                raise SystemExit(f'Cannot find microcode procedure {jsr.group(1)}')
            sub = calc_cycles(desc.chunks[proc].start * desc.entry_len, code, True, desc, was_ni)
            if recurse:
                s += sub
        k += 1
    return s


def fix_cycles(code, desc):
    elen = desc.entry_len

    def fixone(ref, uaddr):
        total = calc_cycles(uaddr, code, True, desc, [False])
        main = calc_cycles(uaddr, code, False, desc, [False])
        delta = ref - total
        if main + delta > elen:
            delta = elen - main
        if delta > 0:
            for k in range(main - 1, -1, -1):
                code[uaddr + k + delta] = code[uaddr + k]
            for k in range(delta):
                code[uaddr + k] = ''
    for ch in desc.chunks:
        if ch.name != '' and ch.cycles_spec != 0:
            fixone(ch.cycles_spec * desc.cycle_k, ch.start * elen)
    for op in desc.ops:
        fixone(op.cycles * desc.cycle_k, op.op * elen)


def list_unames(code):
    seen, allv = set(), []
    for each in code:
        for tk in each.split(' '):
            if tk in seen:
                continue
            seen.add(tk)
            allv.append(tk)
    # deterministic order: grouped by suffix (only affects bit positions in the ucode word)
    def key(n):
        i = n.find('_')
        return (0, '', n) if i == -1 else (1, n[i + 1:], n)
    return sorted(allv, key=key)


class Param:
    def __init__(self, name, values=None):
        self.name, self.values, self.pos, self.bw = name, values or [], 0, 0


def make_params(unames):
    params = []
    for each in unames:
        if each == '':
            continue
        tokens = each.split('_')
        if len(tokens) == 1:
            params.append(Param(each))
            continue
        for p in params:
            if tokens[1] == p.name:
                if not p.values:
                    raise SystemExit(f'Signal name {tokens[1]} used with and without a suffix')
                p.values.append(tokens[0])
                break
        else:
            params.append(Param(tokens[1], [tokens[0]]))
    for p in params:
        if len(p.values) == 1:
            p.name = p.values[0] + '_' + p.name
            p.values = []
        p.values.sort()
    t = 0
    for p in params:
        p.pos = t
        p.bw = max(math.ceil(math.log2(1 + len(p.values))), 1)
        t += p.bw
    return params


def encode(line, params):
    v = 0
    for each in line.split():
        for m in params:
            if each == m.name:
                v |= 1 << m.pos
                break
            hit = False
            for k, prefix in enumerate(m.values):
                if each == prefix + '_' + m.name:
                    v |= (k + 1) << m.pos
                    hit = True
                    break
            if hit:
                break
        else:
            raise SystemExit(f'Cannot find macro for {each}!')
    return v


def write_files(out, desc, code, params):
    dw = params[-1].pos + params[-1].bw
    if dw > 64:
        raise SystemExit(f'{dw} bits per ucode line')
    aw = math.ceil(math.log2(len(code)))
    base = os.path.basename(out)
    with open(out + '.uc', 'w', newline='\n') as f:
        for each in code:
            f.write(format(encode(each, params), f'0{dw}b') + '\n')
    # <out>.vh (template ucode.vh)
    jsr = next((p for p in params if p.name == 'JSR'), None)
    jsr_chunks = []
    if jsr is not None:
        for ch in desc.chunks:
            if ch.name != '' and ch.name.upper() in jsr.values:
                jsr_chunks.append(ch)
    v = []
    if jsr_chunks:
        v.append('reg jsr_en;')
        v.append(f'reg [{aw - 1}:0] jsr_ua, jsr_ret, uaddr;')
    v.append('')
    for p in params:
        if p.bw != 1:
            v.append(f'// wire [{p.bw - 1}:0] {p.name.lower()}_sel;')
    for p in params:
        if p.bw == 1:
            v.append(f'// wire       {p.name.lower()};')
    v.append(f'reg  [{dw - 1}:0] ucode_rom[0:2**{aw}-1];')
    v.append(('reg  ' if desc.latch else 'wire ') + f'[{dw - 1}:0] ucode_data;')
    v.append('')
    v.append('initial begin')
    v.append(f'    $readmemb("{base}.uc",ucode_rom);')
    v.append('end')
    v.append('')
    if desc.latch:
        v.append('always @(posedge clk) if(!cen) ucode_data = ucode_rom[uaddr];')
    else:
        v.append('assign ucode_data = ucode_rom[uaddr];')
    v.append('')
    for p in params:
        if p.bw == 1:
            v.append(f'assign {p.name.lower():<11}= ucode_data[{p.pos:2d}+:{p.bw}];')
    for p in params:
        if p.bw != 1:
            v.append(f'assign {(p.name.lower() + "_sel"):<11}= ucode_data[{p.pos:2d}+:{p.bw}];')
    if jsr_chunks:
        v.append('')
        v.append('always @* begin')
        v.append('    case( jsr_sel )')
        for ch in jsr_chunks:
            lbl = (ch.name + '_JSR:').upper()
            v.append(f"        {lbl:<12} begin jsr_en=1; jsr_ua = {aw}'h{ch.start:02X}*{aw}'d{desc.entry_len}; end ")
        v.append('        RET_JSR:     begin jsr_en=1; jsr_ua = jsr_ret; end')
        v.append("        default:     begin jsr_en=0; jsr_ua = 'h00; end")
        v.append('    endcase')
        v.append('end')
    with open(out + '.vh', 'w', newline='\n') as f:
        f.write('// Generated by scripts/ucode_gen.py (port of jtframe ucode). Do not edit.\n')
        f.write('\n'.join(v) + '\n')
    # <out>_param.vh (template ucparam.vh)
    tw = math.ceil(math.log2(desc.entry_len * desc.entries))
    p_lines = ['// Generated by scripts/ucode_gen.py (port of jtframe ucode). Do not edit.',
               '// SPDX-License-Identifier: GPL-3.0-or-later', '', '// Control signals']
    for p in params:
        if p.bw != 1:
            items = [f"    {(vv + '_' + p.name).upper():>12} = {p.bw}'d{k + 1}" for k, vv in enumerate(p.values)]
            p_lines.append(f'localparam [{p.bw - 1}:0] // {p.name}')
            p_lines.append(',\n'.join(items) + ';')
            p_lines.append('')
    p_lines.append('// entry points for ucode procedures')
    seqa = {ch.name: ch.start * desc.entry_len for ch in desc.chunks if ch.name != '' and ch.start >= 0}
    for k in sorted(seqa):
        p_lines.append(f"localparam {(k + '_SEQA').upper():<20} = {tw}'h{seqa[k]:X};")
    with open(out + '_param.vh', 'w', newline='\n') as f:
        f.write('\n'.join(p_lines) + '\n')


def make(ucode_dir, src, out_dir, output=None):
    desc = read_desc(os.path.join(ucode_dir, src))
    if desc.entries <= 0 or desc.entry_len <= 0:
        raise SystemExit('entry_len and entries must be set')
    check_duplicated(desc)
    for ch in desc.chunks:
        for m in ch.mnemo:
            if not any(op.name == m for op in desc.ops):
                raise SystemExit(f'Missing OP definition for mnemonic {m}')
    code = expand_all(desc)
    if not desc.ignore_cycles:
        fix_cycles(code, desc)
    params = make_params(list_unames(code))
    name = output or os.path.splitext(src)[0]
    write_files(os.path.join(out_dir, name), desc, code, params)
    print(f'{src} -> {name}.uc/.vh/_param.vh: {len(code)} lines x {params[-1].pos + params[-1].bw} bits')


if __name__ == '__main__':
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    make(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
