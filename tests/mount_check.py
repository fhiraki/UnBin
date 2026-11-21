import os
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test as t


def relocate(image, shift):
    data = bytearray(image)

    def add_le(at):
        data[at : at + 4] = struct.pack("<I", struct.unpack_from("<I", data, at)[0] + shift)

    def add_be(at):
        data[at : at + 4] = struct.pack(">I", struct.unpack_from(">I", data, at)[0] + shift)

    pvd = 16 * 2048
    assert data[pvd] == 1 and data[pvd + 1 : pvd + 6] == b"CD001"
    assert data[17 * 2048] == 255, "only a primary descriptor is supported"
    table_size = struct.unpack_from("<I", data, pvd + 132)[0]
    l_table = struct.unpack_from("<I", data, pvd + 140)[0]
    m_table = struct.unpack_from(">I", data, pvd + 148)[0]
    root = struct.unpack_from("<I", data, pvd + 158)[0]
    root_size = struct.unpack_from("<I", data, pvd + 166)[0]

    def walk(extent, size):
        at = extent * 2048
        end = at + size
        index = 0
        while at < end:
            length = data[at]
            if length == 0:
                at = (at // 2048 + 1) * 2048
                continue
            child = struct.unpack_from("<I", data, at + 2)[0]
            child_size = struct.unpack_from("<I", data, at + 10)[0]
            is_dir = data[at + 25] & 2
            add_le(at + 2)
            add_be(at + 6)
            if is_dir and index >= 2:
                walk(child, child_size)
            index += 1
            at += length

    walk(root, root_size)
    for table, add in ((l_table, add_le), (m_table, add_be)):
        at = table * 2048
        end = at + table_size
        while at < end:
            name = data[at]
            add(at + 2)
            at += 8 + name + (name & 1)
    add_le(pvd + 80)
    add_be(pvd + 84)
    add_le(pvd + 140)
    add_be(pvd + 148)
    if struct.unpack_from("<I", data, pvd + 144)[0]:
        add_le(pvd + 144)
    if struct.unpack_from(">I", data, pvd + 152)[0]:
        add_be(pvd + 152)
    add_le(pvd + 158)
    add_be(pvd + 162)
    return bytes(data)


def main():
    tool = sys.argv[1]
    with tempfile.TemporaryDirectory() as root:
        src = os.path.join(root, "src")
        os.makedirs(os.path.join(src, "DIR"))
        files = {"HELLO.TXT": b"hello from session two\n", "DIR/DATA.BIN": t.payload(30, 9)[:17000]}
        for name, body in files.items():
            t.write(os.path.join(src, name), body)
        base = os.path.join(root, "base.iso")
        subprocess.run(["hdiutil", "makehybrid", "-quiet", "-iso", "-default-volume-name", "EXTRA", "-o", base, src], check=True)
        audio = 250
        shift = audio + 11400
        t.write(os.path.join(root, "audio.bin"), t.payload(31, 300)[: 2352 * audio])
        t.write(os.path.join(root, "data.bin"), t.raw(relocate(t.read(base), shift), 2))
        t.write(os.path.join(root, "extra.cue"),
                'REM SESSION 01\nFILE "audio.bin" BINARY\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n'
                'REM SESSION 02\nFILE "data.bin" BINARY\n  TRACK 02 MODE2/2352\n    INDEX 01 00:00:00\n')
        r = subprocess.run([tool, os.path.join(root, "extra.cue"), os.path.join(root, "out")], capture_output=True, text=True)
        print(r.stderr.strip())
        if r.returncode != 0:
            return 1
        point = os.path.join(root, "mnt")
        os.makedirs(point)
        iso = os.path.join(root, "out", "extra.iso")
        r = subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", point, iso],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("FAIL attach: " + r.stderr.strip())
            return 1
        try:
            ok = all(t.read(os.path.join(point, name)) == body for name, body in files.items())
        except OSError as error:
            print("FAIL read: %s" % error)
            ok = False
        finally:
            subprocess.run(["hdiutil", "detach", "-quiet", point])
        print("ok   aligned ISO mounts and files match" if ok else "FAIL files differ")
        return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
