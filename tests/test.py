import hashlib
import os
import re
import struct
import subprocess
import sys
import tempfile

SYNC = b"\x00" + b"\xff" * 10 + b"\x00"


def payload(seed, sectors):
    out = b""
    counter = 0
    while len(out) < sectors * 2048:
        out += hashlib.sha256(b"%d-%d" % (seed, counter)).digest()
        counter += 1
    return out[: sectors * 2048]


EDC_TABLE = []
for _i in range(256):
    _e = _i
    for _ in range(8):
        _e = (_e >> 1) ^ (0xD8018001 if _e & 1 else 0)
    EDC_TABLE.append(_e)


def edc(data):
    e = 0
    for b in data:
        e = EDC_TABLE[(e ^ b) & 0xFF] ^ (e >> 8)
    return struct.pack("<I", e)


def raw(data, mode):
    out = bytearray()
    for i in range(len(data) // 2048):
        user = data[i * 2048 : (i + 1) * 2048]
        header = SYNC + bytes([0, 2, i % 75, mode])
        if mode == 1:
            out += header + user + edc(header + user) + b"\xee" * 284
        else:
            body = b"\x00\x00\x08\x00" * 2 + user
            out += header + body + edc(body) + b"\xee" * 276
    return bytes(out)


def form2(seed, sectors):
    out = bytearray()
    body = payload(seed, sectors * 2)
    for i in range(sectors):
        user = body[i * 2324 : (i + 1) * 2324]
        out += SYNC + bytes([0, 2, i % 75, 2]) + b"\x01\x01\x64\x00" * 2 + user + b"\x00" * 4
    return bytes(out)


def volume(start, sectors=40):
    data = bytearray(payload(20, sectors))
    data[: 16 * 2048] = bytes(16 * 2048)
    root = start + 20
    record = bytearray(34)
    record[0] = 34
    record[2:6] = struct.pack("<I", root)
    record[6:10] = struct.pack(">I", root)
    record[10:14] = struct.pack("<I", 2048)
    record[25] = 2
    record[32] = 1
    pvd = bytearray(2048)
    pvd[0] = 1
    pvd[1:6] = b"CD001"
    pvd[6] = 1
    pvd[40:72] = b"EXTRA".ljust(32)
    pvd[80:84] = struct.pack("<I", start + sectors)
    pvd[128:130] = struct.pack("<H", 2048)
    pvd[156:190] = record
    end = bytearray(2048)
    end[0] = 255
    end[1:6] = b"CD001"
    directory = bytearray(2048)
    directory[0:34] = record
    directory[34:68] = record
    directory[34 + 33] = 1
    data[16 * 2048 : 17 * 2048] = pvd
    data[17 * 2048 : 18 * 2048] = end
    data[20 * 2048 : 21 * 2048] = directory
    return bytes(data)


def mode2_2336(data):
    out = bytearray()
    for i in range(len(data) // 2048):
        body = b"\x00\x00\x08\x00" * 2 + data[i * 2048 : (i + 1) * 2048]
        out += body + edc(body) + b"\xee" * 276
    return bytes(out)


def wav(pcm):
    return (b"RIFF" + struct.pack("<I", len(pcm) + 36) + b"WAVEfmt " +
            struct.pack("<IHHIIHH", 16, 1, 2, 44100, 176400, 4, 16) + b"data" + struct.pack("<I", len(pcm)) + pcm)


def swap(pcm):
    out = bytearray(pcm)
    out[0::2], out[1::2] = pcm[1::2], pcm[0::2]
    return bytes(out)


def write(path, data):
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())


def read(path):
    with open(path, "rb") as f:
        return f.read()


def msf(frames):
    return "%02d:%02d:%02d" % (frames // 75 // 60, frames // 75 % 60, frames % 75)


def main():
    tool = sys.argv[1]
    failures = []

    def check(name, ok):
        print(("ok   " if ok else "FAIL ") + name)
        if not ok:
            failures.append(name)

    def run(cue, out, *flags):
        return subprocess.run([tool, cue, out, *flags], capture_output=True, text=True)

    with tempfile.TemporaryDirectory() as root:
        d = os.path.join(root, "mode2")
        os.makedirs(d)
        data = payload(1, 300)
        pcm = payload(2, 100)[: 2352 * 80]
        write(os.path.join(d, "data.bin"), raw(data, 2))
        write(os.path.join(d, "audio.bin"), swap(pcm))
        write(os.path.join(d, "disc.cue"),
              'FILE "data.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n'
              'FILE "audio.bin" MOTOROLA\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "disc.cue"), os.path.join(d, "out"))
        check("MODE2/2352 exit", r.returncode == 0)
        check("form 1 has no warning", "warning" not in r.stderr and "note" not in r.stderr)
        check("MODE2/2352 iso", read(os.path.join(d, "out", "disc.iso")) == data)
        check("MOTOROLA wav", read(os.path.join(d, "out", "disc (Track 02).wav")) == wav(pcm))

        d = os.path.join(root, "mixed")
        os.makedirs(d)
        first = payload(3, 200)
        second = payload(4, 150)
        pcm = payload(5, 400)[: 2352 * 300]
        gap = b"\x00" * (2352 * 150)
        write(os.path.join(d, "IMAGE.BIN"), raw(first, 1) + raw(second, 2) + gap + pcm)
        write(os.path.join(d, "image.cue"),
              'REM COMMENT "test"\r\nFILE "C:\\discs\\image.bin" BINARY\r\n'
              "  TRACK 01 MODE1/2352\r\n    INDEX 01 00:00:00\r\n"
              "  TRACK 02 MODE2/2352\r\n    INDEX 01 %s\r\n"
              "  TRACK 03 AUDIO\r\n    INDEX 00 %s\r\n    INDEX 01 %s\r\n" % (msf(200), msf(350), msf(500)))
        r = run(os.path.join(d, "image.cue"), os.path.join(d, "out"))
        check("single bin exit", r.returncode == 0)
        check("single bin iso 1", read(os.path.join(d, "out", "image (Track 01).iso")) == first)
        check("single bin iso 2", read(os.path.join(d, "out", "image (Track 02).iso")) == second)
        check("single bin wav skips pregap", read(os.path.join(d, "out", "image (Track 03).wav")) == wav(pcm))
        r = run(os.path.join(d, "image.cue"), os.path.join(d, "out2"), "--no-wav")
        check("--no-wav", sorted(os.listdir(os.path.join(d, "out2"))) == ["image (Track 01).iso", "image (Track 02).iso"])

        d = os.path.join(root, "xa")
        os.makedirs(d)
        data = payload(10, 60)
        movie = form2(11, 40)
        write(os.path.join(d, "xa.bin"), raw(data, 2) + movie + b"\x00" * 100)
        write(os.path.join(d, "xa.cue"), 'FILE "xa.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "xa.cue"), os.path.join(d, "out"))
        expected = data + b"".join(movie[i * 2352 + 24 : i * 2352 + 24 + 2048] for i in range(40))
        check("form 2 exit", r.returncode == 0)
        check("form 2 iso keeps sector positions", read(os.path.join(d, "out", "xa.iso")) == expected)
        check("form 2 warning", "warning: Track 01" in r.stderr and "40" in r.stderr and "100" in r.stderr)
        check("remainder warning", r.stderr.count("warning: Track 01") == 2)

        d = os.path.join(root, "audio")
        os.makedirs(d)
        pcm = payload(12, 100)[: 2352 * 60]
        graphics = b"".join(pcm[i * 2352 : (i + 1) * 2352] + bytes([i % 64]) * 96 for i in range(60))
        write(os.path.join(d, "a.bin"), pcm)
        write(os.path.join(d, "g.bin"), graphics)
        write(os.path.join(d, "cd.cue"),
              'FILE "a.bin" BINARY\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n'
              'FILE "g.bin" BINARY\n  TRACK 02 CDG\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "cd.cue"), os.path.join(d, "out"))
        check("audio-only exit", r.returncode == 0)
        check("audio-only note", "note:" in r.stderr and "warning" not in r.stderr)
        check("audio-only writes no iso", sorted(os.listdir(os.path.join(d, "out"))) == ["cd (Track 01).wav", "cd (Track 02).wav"])
        check("CDG wav drops subchannel", read(os.path.join(d, "out", "cd (Track 02).wav")) == wav(pcm))

        d = os.path.join(root, "extra")
        os.makedirs(d)
        pcm = payload(21, 300)[: 2352 * 250]
        write(os.path.join(d, "audio.bin"), pcm)
        start = 250 + 11400
        data = volume(start)
        write(os.path.join(d, "data.bin"), raw(data, 2))
        sessions = ('REM SESSION 01\nFILE "audio.bin" BINARY\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n'
                    'REM SESSION 02\nFILE "data.bin" BINARY\n  TRACK 02 MODE2/2352\n    INDEX 01 00:00:00\n')
        write(os.path.join(d, "extra.cue"), sessions)
        r = run(os.path.join(d, "extra.cue"), os.path.join(d, "out"))
        iso = read(os.path.join(d, "out", "extra.iso")) if r.returncode == 0 else b""
        check("CD Extra aligned by session gap", iso[start * 2048 :] == data
              and iso[: start * 2048] == bytes(16 * 2048) + data[16 * 2048 : 18 * 2048] + bytes((start - 18) * 2048))
        check("CD Extra note", "note: Track 02" in r.stderr and str(start) in r.stderr and "warning" not in r.stderr)
        r = run(os.path.join(d, "extra.cue"), os.path.join(d, "raw"), "--no-align")
        check("--no-align keeps the raw track", read(os.path.join(d, "raw", "extra.iso")) == data)
        write(os.path.join(d, "plain.cue"), sessions.replace("REM SESSION 01\n", "").replace("REM SESSION 02\n", ""))
        r = run(os.path.join(d, "plain.cue"), os.path.join(d, "out2"))
        iso = read(os.path.join(d, "out2", "plain.iso")) if r.returncode == 0 else b""
        check("alignment found by scanning", len(iso) == (start + 40) * 2048 and iso[start * 2048 :] == data)
        write(os.path.join(d, "explicit.cue"), sessions.replace(
            "REM SESSION 02\n", "REM LEAD-OUT 01:30:00\nREM SESSION 02\nREM LEAD-IN 01:00:00\nREM PREGAP 00:02:00\n"))
        r = run(os.path.join(d, "explicit.cue"), os.path.join(d, "out3"))
        check("explicit session gap", r.returncode == 0 and os.path.getsize(os.path.join(d, "out3", "explicit.iso")) == (start + 40) * 2048)

        d = os.path.join(root, "pregap")
        os.makedirs(d)
        pcm = payload(22, 200)[: 2352 * 100]
        data = volume(100 + 150)
        write(os.path.join(d, "a.bin"), pcm)
        write(os.path.join(d, "d.bin"), raw(data, 1))
        write(os.path.join(d, "p.cue"),
              'FILE "a.bin" BINARY\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n'
              'FILE "d.bin" BINARY\n  TRACK 02 MODE1/2352\n    PREGAP 00:02:00\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "p.cue"), os.path.join(d, "out"))
        check("PREGAP counts toward the position", r.returncode == 0 and "250" in r.stderr
              and os.path.getsize(os.path.join(d, "out", "p.iso")) == 290 * 2048)
        relative = volume(0)
        write(os.path.join(d, "d.bin"), raw(relative, 1))
        r = run(os.path.join(d, "p.cue"), os.path.join(d, "out4"))
        check("track-relative volume is not padded", read(os.path.join(d, "out4", "p.iso")) == relative and "note" not in r.stderr)
        broken = bytearray(volume(5000))
        broken[20 * 2048 : 21 * 2048] = bytes(2048)
        write(os.path.join(d, "d.bin"), raw(bytes(broken), 1))
        r = run(os.path.join(d, "p.cue"), os.path.join(d, "out5"))
        check("unverifiable position warns", r.returncode == 0 and "warning: Track 02" in r.stderr
              and os.path.getsize(os.path.join(d, "out5", "p.iso")) == 40 * 2048)

        d = os.path.join(root, "damage")
        os.makedirs(d)
        data = volume(0, 60)
        image = bytearray(raw(data, 1))
        for sector in (30, 31, 40):
            image[sector * 2352 + 100] ^= 0xFF
        image[50 * 2352 : 50 * 2352 + 12] = bytes(12)
        write(os.path.join(d, "d.bin"), bytes(image[: 55 * 2352]))
        write(os.path.join(d, "d.cue"), 'FILE "d.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "d.cue"), os.path.join(d, "out"))
        lines = [line for line in r.stderr.splitlines() if line.startswith("warning: Track 01")]
        numbers = [re.findall(r"\d+", line)[1:] for line in lines]
        check("EDC mismatch warning", r.returncode == 0 and ["3", "30"] in numbers)
        check("missing sync warning", ["1"] in numbers)
        check("truncated volume warning", ["60", "55"] in numbers)
        check("damage gives exactly three warnings", len(lines) == 3)
        check("filesystem shown", "[ISO 9660 “EXTRA”]" in r.stdout)

        d = os.path.join(root, "fs")
        os.makedirs(d)
        data = bytearray(volume(0, 40))
        joliet = bytearray(2048)
        joliet[0] = 2
        joliet[1:6] = b"CD001"
        joliet[88:91] = b"%/E"
        boot = bytearray(2048)
        boot[1:6] = b"CD001"
        boot[7:30] = b"EL TORITO SPECIFICATION"
        end = bytes(data[17 * 2048 : 18 * 2048])
        data[17 * 2048 : 20 * 2048] = boot + joliet + end
        data[20 * 2048 + 34 : 20 * 2048 + 40] = b"SP\x07\x01\xbe\xef"
        data[20 * 2048] = 48
        data[1024:1026] = b"BD"
        data[1024 + 36] = 4
        data[1024 + 37 : 1024 + 41] = b"Disk"
        write(os.path.join(d, "h.bin"), raw(bytes(data), 1))
        write(os.path.join(d, "h.cue"), 'FILE "h.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "h.cue"), os.path.join(d, "out"))
        check("hybrid with extensions", "[ISO 9660 + Joliet + Rock Ridge + El Torito / HFS" in r.stdout and "warning" not in r.stderr)
        mac = bytearray(payload(40, 30))
        mac[: 4096] = bytes(4096)
        mac[0:4] = b"ER\x02\x00"
        mac[512:514] = b"PM"
        mac[512 + 8 : 512 + 12] = struct.pack(">I", 1)
        mac[512 + 48 : 512 + 68] = b"Apple_partition_map\x00"
        mac[1024:1026] = b"PM"
        mac[1024 + 8 : 1024 + 12] = struct.pack(">I", 16)
        mac[1024 + 48 : 1024 + 58] = b"Apple_HFS\x00"
        mac[16 * 512 + 1024 : 16 * 512 + 1026] = b"BD"
        mac[16 * 512 + 1024 + 36] = 3
        mac[16 * 512 + 1024 + 37 : 16 * 512 + 1024 + 40] = b"Mac"
        write(os.path.join(d, "m.bin"), raw(bytes(mac), 1))
        write(os.path.join(d, "m.cue"), 'FILE "m.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "m.cue"), os.path.join(d, "out2"))
        check("HFS behind a partition map", "[HFS “Mac”]" in r.stdout and read(os.path.join(d, "out2", "m.iso")) == bytes(mac))
        write(os.path.join(d, "u.bin"), raw(payload(41, 30), 1))
        write(os.path.join(d, "u.cue"), 'FILE "u.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "u.cue"), os.path.join(d, "out3"))
        check("unknown filesystem", r.returncode == 0 and "[ISO" not in r.stdout and "[HFS" not in r.stdout and "warning" not in r.stderr)

        d = os.path.join(root, "multi")
        os.makedirs(d)
        one = volume(0, 40)
        start = 40 + 11400
        two = volume(start, 30)
        write(os.path.join(d, "s1.bin"), raw(one, 1))
        write(os.path.join(d, "s2.bin"), raw(two, 1))
        write(os.path.join(d, "multi.cue"),
              'REM SESSION 01\nFILE "s1.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n'
              'REM SESSION 02\nFILE "s2.bin" BINARY\n  TRACK 02 MODE1/2352\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "multi.cue"), os.path.join(d, "out"))
        expected = bytearray(one + bytes((start - 40) * 2048) + two)
        expected[16 * 2048 : 18 * 2048] = two[16 * 2048 : 18 * 2048]
        check("multisession merged into one iso", r.returncode == 0 and os.listdir(os.path.join(d, "out")) == ["multi.iso"]
              and read(os.path.join(d, "out", "multi.iso")) == bytes(expected))
        check("multisession notes", "note: Track 01" in r.stderr and "note: Track 02" in r.stderr and "warning" not in r.stderr)
        r = run(os.path.join(d, "multi.cue"), os.path.join(d, "raw"), "--no-align")
        check("multisession --no-align keeps tracks apart", r.returncode == 0
              and read(os.path.join(d, "raw", "multi (Track 01).iso")) == one
              and read(os.path.join(d, "raw", "multi (Track 02).iso")) == two)
        r = run(os.path.join(d, "multi.cue"), os.path.join(d, "out"))
        check("existing output is refused", r.returncode != 0 and "--force" in r.stderr
              and read(os.path.join(d, "out", "multi.iso")) == bytes(expected))
        write(os.path.join(d, "out", "multi.iso"), b"old")
        r = run(os.path.join(d, "multi.cue"), os.path.join(d, "out"), "--force")
        check("--force overwrites and leaves no .part", r.returncode == 0 and os.listdir(os.path.join(d, "out")) == ["multi.iso"]
              and read(os.path.join(d, "out", "multi.iso")) == bytes(expected))
        busy = bytearray(one)
        busy[17 * 2048 : 18 * 2048] = payload(50, 1)
        write(os.path.join(d, "s1.bin"), raw(bytes(busy), 1))
        r = run(os.path.join(d, "multi.cue"), os.path.join(d, "out2"))
        check("sessions stay apart when the descriptors do not fit", r.returncode == 0
              and sorted(os.listdir(os.path.join(d, "out2"))) == ["multi (Track 01).iso", "multi (Track 02).iso"])

        d = os.path.join(root, "hidden")
        os.makedirs(d)
        secret = payload(60, 250)[: 2352 * 200]
        pcm = payload(61, 150)[: 2352 * 120]
        write(os.path.join(d, "h.bin"), secret + pcm)
        cue = ('FILE "h.bin" BINARY\n  TRACK 01 AUDIO\n    FLAGS PRE DCP\n    INDEX 00 00:00:00\n    INDEX 01 %s\n' % msf(200))
        write(os.path.join(d, "h.cue"), cue)
        r = run(os.path.join(d, "h.cue"), os.path.join(d, "out"))
        check("hidden track written as Track 00", r.returncode == 0
              and read(os.path.join(d, "out", "h (Track 00).wav")) == wav(secret)
              and read(os.path.join(d, "out", "h (Track 01).wav")) == wav(pcm))
        check("hidden track and pre-emphasis notes", "note: Track 00" in r.stderr and "note: Track 01" in r.stderr)
        quiet = b"".join(struct.pack("<h", (i % 5) - 2) for i in range(1176 * 200))
        write(os.path.join(d, "h.bin"), quiet + pcm)
        write(os.path.join(d, "h.cue"), cue.replace("    FLAGS PRE DCP\n", ""))
        r = run(os.path.join(d, "h.cue"), os.path.join(d, "out2"))
        check("silent pregap is not a hidden track", r.returncode == 0 and "note: Track" not in r.stderr
              and os.listdir(os.path.join(d, "out2")) == ["h (Track 01).wav"])

        d = os.path.join(root, "m2336")
        os.makedirs(d)
        data = payload(6, 120)
        write(os.path.join(d, "a.bin"), mode2_2336(data))
        write(os.path.join(d, "a.cue"), 'FILE a.bin BINARY\n  TRACK 01 MODE2/2336\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "a.cue"), os.path.join(d, "out"))
        check("MODE2/2336 iso", r.returncode == 0 and read(os.path.join(d, "out", "a.iso")) == data)

        d = os.path.join(root, "cooked")
        os.makedirs(d)
        data = payload(7, 90)
        write(os.path.join(d, "b.iso"), data)
        write(os.path.join(d, "b.cue"), 'FILE "b.iso" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n')
        r = run(os.path.join(d, "b.cue"), d)
        check("refuses to overwrite input", r.returncode != 0 and read(os.path.join(d, "b.iso")) == data)
        r = run(os.path.join(d, "b.cue"), os.path.join(d, "out"))
        check("MODE1/2048 iso", r.returncode == 0 and read(os.path.join(d, "out", "b.iso")) == data)

        write(os.path.join(d, "c.iso"), data)
        write(os.path.join(d, "C.cue"), 'FILE "C.ISO" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n')
        if os.path.exists(os.path.join(d, "C.ISO")):
            r = run(os.path.join(d, "C.cue"), d, "--force")
            check("refuses to overwrite input under another case", r.returncode == 1 and read(os.path.join(d, "c.iso")) == data
                  and not os.path.exists(os.path.join(d, "C.iso.part")))

        d = os.path.join(root, "bad")
        os.makedirs(d)
        write(os.path.join(d, "z.bin"), payload(70, 4))
        write(os.path.join(d, "zero.cue"), 'FILE "z.bin" BINARY\n  TRACK 01 MODE1/0\n    INDEX 01 00:00:00\n')
        check("zero sector size fails cleanly", run(os.path.join(d, "zero.cue"), os.path.join(d, "o")).returncode == 1)
        write(os.path.join(d, "neg.cue"), 'FILE "z.bin" BINARY\n  TRACK 01 AUDIO\n    INDEX 01 -1:00:00\n'
              '  TRACK 02 AUDIO\n    INDEX 01 99999999999999999:00:00\n')
        check("bad index does not crash", run(os.path.join(d, "neg.cue"), os.path.join(d, "o")).returncode in (0, 1))
        write(os.path.join(d, "ok.cue"), 'FILE "z.bin" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n')
        check("unknown option fails", run(os.path.join(d, "ok.cue"), os.path.join(d, "o"), "--forse").returncode == 1
              and not os.path.exists(os.path.join(d, "o", "ok.iso")))
        write(os.path.join(d, "missing.cue"), 'FILE "nothing.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
        check("missing bin fails", run(os.path.join(d, "missing.cue"), d).returncode != 0)
        write(os.path.join(d, "x.wav"), b"RIFF")
        write(os.path.join(d, "wave.cue"), 'FILE "x.wav" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n')
        check("WAVE cue fails", run(os.path.join(d, "wave.cue"), d).returncode != 0)
        write(os.path.join(d, "empty.cue"), "REM nothing\n")
        check("empty cue fails", run(os.path.join(d, "empty.cue"), d).returncode != 0)

    print("%d failed" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
