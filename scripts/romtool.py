#!/usr/bin/env python3
# Super Dodge Ball MiSTer core -- ROM layout tool: MRA generator, stream builder, checks.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The ioctl index 0 stream (docs/MRA_FORMAT.md, rtl/sdb/sdb_loader.sv):
#   000000 maincpu 64 KB | 010000 audiocpu 32 KB | 018000 mcu 16 KB | 01C000 text 256 KB |
#   05C000 sprites 256 KB | 09C000 adpcm 128 KB | 0BC000 proms 2 KB      (total 0BC800 bytes)
# Sets and ROMs are MAME 0.289 technos/spdodgeb.cpp.
#
#   python scripts/romtool.py mra                    write MRA/*.mra
#   python scripts/romtool.py stream <set> <out>     build the stream from the zips (simulation)
#   python scripts/romtool.py check [listxml]        verify the zips (and MAME -listxml) against the tables
import argparse
import os
import sys
import zipfile
import zlib

ROMDIR = r'C:\Users\klest\Downloads\mame\roms'
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

REGIONS = [  # name, size, stream offset
    ('maincpu', 0x10000, 0x000000),
    ('audiocpu', 0x08000, 0x010000),
    ('mcu', 0x04000, 0x018000),
    ('text', 0x40000, 0x01C000),
    ('sprites', 0x40000, 0x05C000),
    ('adpcm', 0x20000, 0x09C000),
    ('proms', 0x00800, 0x0BC000),
]
STREAM_SIZE = 0x0BC800

# region -> list of (file, crc, region offset, size, file offset)
COMMON = {
    'audiocpu': [('22j5-0.33', 'c31e264e', 0, 0x8000, 0)],
    'mcu': [('22ja-0.162', '7162a97b', 0, 0x4000, 0)],
    'adpcm': [('22j6-0.83', '744a26e3', 0, 0x10000, 0), ('22j7-0.82', '2fa1de21', 0x10000, 0x10000, 0)],
}
SETS = {
    'spdodgeb': dict(
        title='Super Dodge Ball (US)', parent=None, manufacturer='Technos Japan', year='1987',
        zips=['spdodgeb.zip'],
        roms={
            'maincpu': [('22a-04.139', '66071fda', 0, 0x10000, 0)],
            'text': [('22a-4.121', 'acc26051', 0, 0x20000, 0), ('22a-3.107', '10bb800d', 0x20000, 0x20000, 0)],
            'sprites': [('22a-1.2', '3bd1c3ec', 0, 0x20000, 0), ('22a-2.35', '409e1be1', 0x20000, 0x20000, 0)],
            'proms': [('mb7132e.158', '7e623722', 0, 0x400, 0), ('mb7122e.159', '69706e8d', 0x400, 0x400, 0)],
        }),
    'nkdodge': dict(
        title='Nekketsu Koukou Dodgeball Bu (Japan)', parent='spdodgeb', manufacturer='Technos Japan',
        year='1987', zips=['nkdodge.zip', 'spdodgeb.zip'],
        roms={
            'maincpu': [('22j4-0.139', 'aa674fd8', 0, 0x10000, 0)],
            'text': [('tj22j4-0.121', 'd2922b3f', 0, 0x20000, 0), ('tj22j3-0.107', '79cd1315', 0x20000, 0x20000, 0)],
            'sprites': [('tj22j1-0.2', '9ed27a8d', 0, 0x20000, 0), ('tj22j2-0.35', '768934f9', 0x20000, 0x20000, 0)],
            'proms': [('22j8-0.158', 'c368440f', 0, 0x400, 0), ('22j9-0.159', '6059f401', 0x400, 0x400, 0)],
        }),
    'nkdodgeb': dict(
        title='Nekketsu Koukou Dodgeball Bu (Japan, bootleg)', parent='spdodgeb', manufacturer='bootleg',
        year='1987', zips=['nkdodgeb.zip', 'spdodgeb.zip'],
        roms={
            'maincpu': [('12.bin', 'aa674fd8', 0, 0x10000, 0)],
            'text': [('10.bin', '442326fd', 0, 0x10000, 0), ('11.bin', '2140b070', 0x10000, 0x10000, 0),
                     ('9.bin', '18660ac1', 0x20000, 0x10000, 0), ('8.bin', '5caae3c9', 0x30000, 0x10000, 0)],
            'sprites': [('2.bin', '1271583e', 0, 0x10000, 0), ('1.bin', '5ae6cccf', 0x10000, 0x10000, 0),
                        ('4.bin', 'f5022822', 0x20000, 0x10000, 0), ('3.bin', '05a71179', 0x30000, 0x10000, 0)],
            # MAME loads the 2 KB 27s191 at 0 and the 82s137 over its second half: only the first
            # 0x400 bytes of the 27s191 are used.
            'proms': [('27s191.bin', '317e42ea', 0, 0x400, 0), ('82s137.bin', '6059f401', 0x400, 0x400, 0)],
        }),
}

DIPS = '''    <switches default="FF,C6" base="16">
        <dip bits="0,2" name="Coin A" ids="4C/1C,3C/1C,2C/1C,1C/5C,1C/4C,1C/3C,1C/2C,1C/1C"/>
        <dip bits="3,5" name="Coin B" ids="4C/1C,3C/1C,2C/1C,1C/5C,1C/4C,1C/3C,1C/2C,1C/1C"/>
        <dip bits="6" name="Flip Screen" ids="On,Off"/>
        <dip bits="7" name="Demo Sounds" ids="Off,On"/>
        <dip bits="9" name="Unknown" ids="On,Off"/>
        <dip bits="10" name="Allow Continue" ids="No,Yes"/>
        <dip bits="14,15" name="Difficulty" ids="Very Hard,Hard,Easy,Normal"/>
    </switches>
'''


def region_parts(setname):
    s = SETS[setname]
    out = {}
    for name, _, _ in REGIONS:
        out[name] = s['roms'].get(name) or COMMON[name]
    return out


def find_file(zips, name, crc):
    for z in zips:
        path = os.path.join(ROMDIR, z)
        if not os.path.exists(path):
            continue
        with zipfile.ZipFile(path) as zf:
            for info in zf.infolist():
                if info.filename == name or format(info.CRC, '08x') == crc:
                    return zf.read(info)
    raise SystemExit(f'{name} ({crc}) not found in {zips}')


def build_stream(setname):
    s = SETS[setname]
    out = bytearray(STREAM_SIZE)
    parts = region_parts(setname)
    for name, size, base in REGIONS:
        region = bytearray(size)
        for fname, crc, roff, length, foff in parts[name]:
            data = find_file(s['zips'], fname, crc)
            if format(zlib.crc32(data), '08x') != crc:
                raise SystemExit(f'{fname}: CRC mismatch')
            region[roff:roff + length] = data[foff:foff + length]
        out[base:base + size] = region
    return bytes(out)


def write_mra(setname):
    s = SETS[setname]
    parts = region_parts(setname)
    lines = []
    lines.append('<!--')
    lines.append(f'  {s["title"]} - {s["manufacturer"]} {s["year"]} - MRA for the SuperDodgeBall MiSTer core.')
    lines.append(f'  MAME set {setname} (MAME 0.289 technos/spdodgeb.cpp). No ROM data is embedded in this file.')
    lines.append('  Generated by scripts/romtool.py mra ; layout documented in docs/MRA_FORMAT.md.')
    lines.append('')
    lines.append('  ioctl index 0 stream (hps_io WIDE=0, bytes):')
    for name, size, base in REGIONS:
        lines.append(f'    {base:06X}-{base + size - 1:06X}  {name}')
    lines.append('')
    lines.append('  DIP switches (index 254): byte 0 = DSW (3001); byte 1 = difficulty (IN0 bits 7-6) and the')
    lines.append('  MCU port 5 DIPs (bits 2-1). MAME port values, active low.')
    lines.append('-->')
    lines.append('<misterromdescription>')
    lines.append(f'    <name>{s["title"]}</name>')
    lines.append(f'    <setname>{setname}</setname>')
    if s['parent']:
        lines.append(f'    <parent>{s["parent"]}</parent>')
    lines.append('    <rbf>SuperDodgeBall</rbf>')
    lines.append('    <mameversion>0289</mameversion>')
    lines.append(f'    <year>{s["year"]}</year>')
    lines.append(f'    <manufacturer>{s["manufacturer"]}</manufacturer>')
    lines.append('    <category>Sports / Dodgeball</category>')
    lines.append('    <players>2</players>')
    lines.append('    <joystick>8-way</joystick>')
    lines.append('    <rotation>horizontal</rotation>')
    lines.append('    <buttons names="Throw,Pass,Start,Coin,Pause" default="A,B,Start,Select,L"/>')
    lines.append('')
    lines.append(DIPS.rstrip('\n'))
    lines.append('')
    lines.append(f'    <rom index="0" zip="{"|".join(s["zips"])}" md5="None">')
    for name, size, base in REGIONS:
        lines.append(f'        <!-- {base:06X} {name} -->')
        for fname, crc, roff, length, foff in parts[name]:
            attrs = f'name="{fname}" crc="{crc}"'
            if foff:
                attrs += f' offset="0x{foff:X}"'
            if setname == 'nkdodgeb' and fname == '27s191.bin':
                attrs += f' length="0x{length:X}"'
            lines.append(f'        <part {attrs}/>')
    lines.append('    </rom>')
    lines.append('</misterromdescription>')
    if s['parent'] is None:
        path = os.path.join(REPO, 'MRA', f'{s["title"]}.mra')
    else:
        path = os.path.join(REPO, 'MRA', '_alternatives', '_Super Dodge Ball', f'{s["title"]}.mra')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', newline='\r\n') as f:
        f.write('\n'.join(lines) + '\n')
    print('wrote', os.path.relpath(path, REPO))


def check(listxml):
    for setname in SETS:
        st = build_stream(setname)
        print(f'{setname}: stream {len(st):#x} bytes OK (all CRCs match)')
    if listxml:
        import xml.etree.ElementTree as ET
        root = ET.parse(listxml).getroot()
        for m in root.findall('machine'):
            name = m.get('name')
            if name not in SETS:
                continue
            parts = region_parts(name)
            have = {(p[1], r) for r, lst in parts.items() for p in lst}
            for rom in m.findall('rom'):
                key = (rom.get('crc'), rom.get('region'))
                if key not in have:
                    raise SystemExit(f'{name}: listxml ROM {rom.get("name")} {key} not in table')
            print(f'{name}: matches MAME -listxml')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['mra', 'stream', 'check'])
    ap.add_argument('args', nargs='*')
    a = ap.parse_args()
    if a.cmd == 'mra':
        for sn in SETS:
            write_mra(sn)
    elif a.cmd == 'stream':
        data = build_stream(a.args[0])
        with open(a.args[1], 'wb') as f:
            f.write(data)
        print(f'wrote {a.args[1]} ({len(data):#x} bytes)')
    else:
        check(a.args[0] if a.args else None)
