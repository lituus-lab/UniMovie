# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## MPEG transport stream: `.ts`, and the `.m2ts`/`.mts` an AVCHD camcorder
## writes.
##
## A stream is a flat run of fixed-size packets, each tagged with a program
## identifier. Two tables say what is in it: the program association table on
## PID 0 names a program map table, and that names one PID per elementary
## stream with its type. There is no header, no index and no duration — a
## transport stream is meant to be tuned into halfway through, so everything
## this reader reports is assembled by walking packets.
##
## **Dimensions come from the sequence parameter set.** A transport stream does
## not carry them; they live in the coded stream itself. Reading a parameter
## set is not decoding — no pixel is produced, and the same bytes are what a
## backend would be handed — but it is the one place this library looks inside
## an elementary stream, and it does so only for H.264.

import contracts
import ./types

const
  PacketSizes = [188, 192, 204]
    ## 188 is the standard. 192 is what Blu-ray and AVCHD write, a four-byte
    ## arrival timestamp ahead of each packet. 204 adds Reed-Solomon parity
    ## that is not used here.
  MaxScanPackets = 200_000
    ## Enough for the tables and a first frame in any real file, and a bound on
    ## how long a hostile one can hold this reader.
  PtsPerSecond = 90_000
    ## The clock every timestamp in a transport stream is counted in.

func syncScore(data: string; size, offset: int): int =
  ## How many packets in a row start with the sync byte at this spacing. A
  ## transport stream is recognised by its rhythm rather than by a magic
  ## number, because it has none.
  var at = offset
  while at < data.len and result < 16:
    if data[at] != '\x47': break
    inc result
    at += size

func packetLayout(data: string): tuple[size, offset: int] =
  ## The packet size and where the first packet starts, or `(0, 0)` when the
  ## bytes have no transport-stream rhythm at all.
  ##
  ## Both are discovered rather than assumed: a `.m2ts` and a `.ts` differ only
  ## in the four bytes ahead of each packet, and the file extension is not
  ## evidence.
  for size in PacketSizes:
    for offset in 0 ..< min(size * 2, max(data.len - size, 1)):
      if syncScore(data, size, offset) >= 8:
        return (size, offset)
  (0, 0)

type Packet = object
  ## One packet's identity and the span of its payload.
  pid: int
  start: bool ## whether a PES or table starts in this packet
  at, size: int

func parsePacket(data: string; at, size: int): Packet =
  ## Split a packet into its header and payload. A packet carrying only an
  ## adaptation field — padding, or a clock reference — has an empty payload,
  ## which the caller skips.
  result.pid = -1
  if at + 4 > data.len or data[at] != '\x47': return
  let b1 = int(uint8(data[at + 1]))
  let b2 = int(uint8(data[at + 2]))
  let b3 = int(uint8(data[at + 3]))
  if (b1 and 0x80) != 0: return # transport error indicator
  result.pid = ((b1 and 0x1F) shl 8) or b2
  result.start = (b1 and 0x40) != 0
  var payload = at + 4
  if (b3 and 0x20) != 0: # an adaptation field precedes the payload
    if payload >= data.len: return
    payload += 1 + int(uint8(data[payload]))
  if (b3 and 0x10) == 0 or payload >= at + size or payload > data.len:
    result.pid = -1 # no payload in this packet
    return
  result.at = payload
  result.size = min(at + size, data.len) - payload

func streamCodec(streamType: int): tuple[kind: TrackKind; codec: string] =
  ## What a program map table's stream type means. The codes are the ones MP4
  ## uses, so a caller registers one backend per codec across every container.
  case streamType
  of 0x01, 0x02: (tkVideo, "mp2v")
  of 0x10: (tkVideo, "mp4v")
  of 0x1B: (tkVideo, "avc1")
  of 0x24: (tkVideo, "hvc1")
  of 0x33: (tkVideo, "vvc1")
  of 0x03, 0x04: (tkAudio, "mp4a")
  of 0x0F, 0x11: (tkAudio, "mp4a")
  of 0x81, 0x87: (tkAudio, "ac-3")
  of 0x82, 0x85, 0x86: (tkAudio, "dts ")
  else: (tkOther, "")


type BitCursor = object
  ## A bit position in a byte string, for the exp-Golomb coding a sequence
  ## parameter set uses.
  data: string
  bit: int

proc readBit(cursor: var BitCursor): int =
  ## One bit, most significant first. Reading past the end yields zero rather
  ## than raising: a parameter set truncated by a lost packet should leave the
  ## dimensions unusable, not stop the file being catalogued.
  if cursor.bit >= cursor.data.len * 8: return 0
  let index = cursor.bit shr 3
  let shift = 7 - (cursor.bit and 7)
  inc cursor.bit
  (int(uint8(cursor.data[index])) shr shift) and 1

proc readBits(cursor: var BitCursor; count: int): int =
  ## The next `count` bits as an unsigned value.
  for _ in 0 ..< count: result = (result shl 1) or cursor.readBit()

proc readUe(cursor: var BitCursor): int =
  ## An unsigned exp-Golomb value: a run of zeros, a one, then that many more
  ## bits. The coding H.264 uses for almost every field.
  var zeros = 0
  while zeros < 32 and cursor.readBit() == 0: inc zeros
  if zeros == 0: return 0
  ((1 shl zeros) - 1) + cursor.readBits(zeros)

proc readSe(cursor: var BitCursor): int =
  ## A signed exp-Golomb value: the unsigned one folded onto the integers.
  let value = cursor.readUe()
  if (value and 1) != 0: (value + 1) div 2 else: -(value div 2)

func unescape(payload: string): string =
  ## Undo H.264's emulation prevention: a `00 00 03` in the byte stream stands
  ## for `00 00`, so that no payload can contain a start code. Left in place,
  ## the parser below would read the 03 as data and every field after it would
  ## be wrong.
  var zeros = 0
  for character in payload:
    if zeros >= 2 and character == '\x03':
      zeros = 0
      continue
    result.add character
    zeros = if character == '\x00': zeros + 1 else: 0

proc spsDimensions(sps: string): tuple[width, height: int] =
  ## The picture size a sequence parameter set declares.
  ##
  ## The fields before it have to be walked because every one is variable
  ## width, which is why this reads the profile, the scaling lists and the
  ## reference-frame counts it otherwise has no use for.
  if sps.len < 4: return
  let payload = unescape(sps[1 ..< sps.len])
  var cursor = BitCursor(data: payload)
  let profile = cursor.readBits(8)
  discard cursor.readBits(8) # constraint flags and reserved bits
  discard cursor.readBits(8) # level
  discard cursor.readUe() # seq_parameter_set_id
  var chroma = 1
  if profile in [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]:
    chroma = cursor.readUe()
    if chroma == 3: discard cursor.readBit() # separate_colour_plane_flag
    discard cursor.readUe() # bit_depth_luma_minus8
    discard cursor.readUe() # bit_depth_chroma_minus8
    discard cursor.readBit() # qpprime_y_zero_transform_bypass_flag
    if cursor.readBit() == 1: # seq_scaling_matrix_present_flag
      let lists = if chroma != 3: 8 else: 12
      for index in 0 ..< lists:
        if cursor.readBit() == 1:
          # A scaling list is a run of deltas ending when the scale returns to
          # its start; the values are not needed, only the bits consumed.
          var last = 8
          var next = 8
          let size = if index < 6: 16 else: 64
          for _ in 0 ..< size:
            if next != 0: next = (last + cursor.readSe() + 256) mod 256
            last = if next == 0: last else: next
  discard cursor.readUe() # log2_max_frame_num_minus4
  let order = cursor.readUe()
  if order == 0: discard cursor.readUe()
  elif order == 1:
    discard cursor.readBit()
    discard cursor.readSe()
    discard cursor.readSe()
    for _ in 0 ..< cursor.readUe(): discard cursor.readSe()
  discard cursor.readUe() # max_num_ref_frames
  discard cursor.readBit() # gaps_in_frame_num_value_allowed_flag
  let widthMbs = cursor.readUe() + 1
  let heightMapUnits = cursor.readUe() + 1
  let frameMbsOnly = cursor.readBit()
  if frameMbsOnly == 0: discard cursor.readBit() # mb_adaptive_frame_field_flag
  discard cursor.readBit() # direct_8x8_inference_flag

  var width = widthMbs * 16
  var height = (2 - frameMbsOnly) * heightMapUnits * 16
  if cursor.readBit() == 1: # frame_cropping_flag
    # Cropping is in chroma units, which is what makes 1080 out of 1088.
    let left = cursor.readUe()
    let right = cursor.readUe()
    let top = cursor.readUe()
    let bottom = cursor.readUe()
    let subWidth = if chroma in [1, 2]: 2 else: 1
    let subHeight = if chroma == 1: 2 else: 1
    width -= (left + right) * subWidth
    height -= (top + bottom) * subHeight * (2 - frameMbsOnly)
  if width in 1 .. MaxDimension and height in 1 .. MaxDimension:
    (width, height)
  else:
    (0, 0)


func readPts(data: string; at: int): int64 =
  ## A presentation timestamp out of a PES header: 33 bits split across five
  ## bytes by marker bits, which is why it is not simply read as an integer.
  ## -1 when the bytes are not a timestamp.
  if at + 5 > data.len: return -1
  let b0 = int(uint8(data[at]))
  if (b0 and 0xF0) notin [0x20, 0x30]: return -1
  result = int64((b0 shr 1) and 0x07) shl 30
  result = result or (int64(uint8(data[at + 1])) shl 22)
  result = result or ((int64(uint8(data[at + 2])) shr 1) shl 15)
  result = result or (int64(uint8(data[at + 3])) shl 7)
  result = result or (int64(uint8(data[at + 4])) shr 1)

func isMpegTs*(data: string): bool =
  ## Whether these bytes have a transport stream's rhythm: eight packets in a
  ## row starting with the sync byte at one of the three packet sizes.
  ##
  ## The format carries no magic number, so this is the only way to recognise
  ## it — and the reason it is tried after every format that has one.
  packetLayout(data).size > 0

proc readMpegTs*(data: string): Movie {.contractual.} =
  ## Demultiplex a transport stream: its elementary streams, their codecs, the
  ## picture size of an H.264 one, and the duration its timestamps span.
  ##
  ## Everything is assembled by walking packets, because the format carries no
  ## header. The duration is the distance between the first and last
  ## presentation timestamp on the video stream, which is what the file
  ## actually spans rather than what it declares — a transport stream declares
  ## nothing.
  ##
  ## Nothing is required of the caller: every byte comes from a file, so the
  ## checks are in the body and raise `MovieError`.
  ensure:
    result.tracks.len > 0
  body:
    let layout = packetLayout(data)
    if layout.size == 0:
      raise newException(MovieError, "ts: no transport stream rhythm")
    result.format = if layout.size == 192: "m2ts" else: "mpegts"
    result.timescale = PtsPerSecond

    var pmtPid = -1
    var streams: seq[tuple[pid, streamType: int]]
    var minPts, maxPts: int64 = -1
    var ptsCount = 0
    var videoPid = -1
    var sps = ""
    var pending = "" # a PES payload being gathered, for the parameter set

    var at = layout.offset
    var scanned = 0
    while at + layout.size <= data.len and scanned < MaxScanPackets:
      inc scanned
      let packet = parsePacket(data, at, layout.size)
      at += layout.size
      if packet.pid < 0: continue

      if packet.pid == 0 and packet.start and streams.len == 0:
        # Program association table: skip the pointer field and the eight-byte
        # section header, then read program/PID pairs until the CRC.
        var section = packet.at + 1 + int(uint8(data[packet.at]))
        if section + 8 > data.len: continue
        let length = ((int(uint8(data[section + 1])) and 0x0F) shl 8) or
                      int(uint8(data[section + 2]))
        var entry = section + 8
        let stop = min(section + 3 + length - 4, data.len - 4)
        while entry + 4 <= stop:
          let program = (int(uint8(data[entry])) shl 8) or int(uint8(data[
              entry + 1]))
          let pid = ((int(uint8(data[entry + 2])) and 0x1F) shl 8) or
                     int(uint8(data[entry + 3]))
          if program != 0: pmtPid = pid
          entry += 4
      elif packet.pid == pmtPid and packet.start and streams.len == 0:
        # Program map table: one entry per elementary stream.
        var section = packet.at + 1 + int(uint8(data[packet.at]))
        if section + 12 > data.len: continue
        let length = ((int(uint8(data[section + 1])) and 0x0F) shl 8) or
                      int(uint8(data[section + 2]))
        let infoLength = ((int(uint8(data[section + 10])) and 0x0F) shl 8) or
                          int(uint8(data[section + 11]))
        var entry = section + 12 + infoLength
        let stop = min(section + 3 + length - 4, data.len - 5)
        while entry + 5 <= stop:
          let streamType = int(uint8(data[entry]))
          let pid = ((int(uint8(data[entry + 1])) and 0x1F) shl 8) or
                     int(uint8(data[entry + 2]))
          let esLength = ((int(uint8(data[entry + 3])) and 0x0F) shl 8) or
                          int(uint8(data[entry + 4]))
          streams.add (pid, streamType)
          if videoPid < 0 and streamCodec(streamType).kind == tkVideo:
            videoPid = pid
          entry += 5 + esLength
      elif packet.pid == videoPid and packet.size > 0:
        if packet.start and packet.at + 9 <= data.len and
            data[packet.at ..< packet.at + 3] == "\x00\x00\x01":
          let flags = int(uint8(data[packet.at + 7]))
          if (flags and 0x80) != 0:
            let pts = readPts(data, packet.at + 9)
            if pts >= 0:
              # Smallest and largest, not first and last: B-frames are stored
              # out of presentation order, so the last timestamp seen is not
              # the latest one shown.
              if minPts < 0 or pts < minPts: minPts = pts
              if pts > maxPts: maxPts = pts
              inc ptsCount
        if sps.len == 0 and pending.len < 1 shl 16:
          pending.add data[packet.at ..< packet.at + packet.size]

    if streams.len == 0:
      raise newException(MovieError, "ts: no program map table")

    # The sequence parameter set is NAL unit type 7, found by its start code.
    if sps.len == 0 and pending.len > 4:
      var index = 0
      while index + 4 < pending.len:
        if pending[index] == '\x00' and pending[index + 1] == '\x00' and
            pending[index + 2] == '\x01':
          let header = int(uint8(pending[index + 3]))
          if (header and 0x1F) == 7:
            var stop = index + 4
            while stop + 3 < pending.len and
                not (pending[stop] == '\x00' and pending[stop + 1] == '\x00' and
                     pending[stop + 2] == '\x01'):
              inc stop
            sps = pending[index + 3 ..< min(stop, pending.len)]
            break
        inc index

    for stream in streams:
      let named = streamCodec(stream.streamType)
      if named.kind == tkOther and named.codec.len == 0: continue
      var track = Track(id: stream.pid, kind: named.kind, codec: named.codec,
                        timescale: PtsPerSecond)
      if track.kind == tkVideo and track.codec == "avc1" and sps.len > 0:
        let size = spsDimensions(sps)
        track.width = size.width
        track.height = size.height
      result.tracks.add track
    if result.tracks.len == 0:
      raise newException(MovieError, "ts: no elementary stream this build names")

    if minPts >= 0 and maxPts > minPts and ptsCount > 1:
      # The timestamps span one interval fewer than there are frames: ten
      # frames at ten a second are 0.9 seconds apart and one second long. The
      # average interval is added back so the answer is the playing time rather
      # than the distance between the outermost frames.
      let span = maxPts - minPts
      result.duration = span + span div int64(ptsCount - 1)
      for track in result.tracks.mitems: track.duration = result.duration

proc readMpegTsFile*(path: string): Movie {.contractual.} =
  ## `readMpegTs` over a file. A path that cannot be opened raises `IOError`,
  ## which is what separates a missing file from a malformed one.
  require:
    path.len > 0
  body:
    readMpegTs(readFile(path))


