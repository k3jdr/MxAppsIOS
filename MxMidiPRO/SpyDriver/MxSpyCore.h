//
//  MxSpyCore.h — MxMidiPRO Spy
//
//  The part of the spy driver that copies outgoing MIDI onto the spy's private source. It is kept apart from the
//  CFPlugIn glue (MxSpyDriver.c) so Tools/MxSpyHarness can run the same code in an ordinary process.
//
//  Wire format: every MIDIPacket the MIDI server sends to any destination is re-sent on the spy source as one or
//  more system-exclusive messages (one per 4096 bytes of the packet):
//
//      F0 7D 4D 78 <version>
//         <destination unique ID: 5 groups of 7 bits, least significant first>
//         <host time: 10 groups of 7 bits, least significant first>
//         <the packet's bytes, 7-in-8 packed: a byte of high bits, then up to 7 low-7-bit bytes>
//      F7
//
//  7D is the MMA's ID for non-commercial use; 4D 78 is "Mx". MxMidiPRO decodes it in SpyFeed.swift.
//

#ifndef MxSpyCore_h
#define MxSpyCore_h

#include <CoreMIDI/CoreMIDI.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MXSPY_SYSEX_ID      0x7D
#define MXSPY_TAG_1         0x4D
#define MXSPY_TAG_2         0x78
#define MXSPY_VERSION       0x01
#define MXSPY_HEADER_BYTES  20      /* F0 7D 4D 78 version, 5 ID groups, 10 time groups */
#define MXSPY_MAX_CHUNK     4096    /* bytes of the original packet per spy message */

/// The spy source's unique ID ("MxSp"). The source is private, so it isn't listed anywhere; MxMidiPRO finds it with
/// MIDIObjectFindByUniqueID (MIDIEngine.spySourceUniqueID must match).
#define MXSPY_SOURCE_UNIQUE_ID  0x4D785370

static inline size_t MxSpyEncodedSize(size_t rawLength) {
    return MXSPY_HEADER_BYTES + rawLength + (rawLength + 6) / 7 + 1;
}

/// Writes one spy message for `raw` into `out` (which holds MxSpyEncodedSize(rawLength) bytes); returns its length.
size_t MxSpyEncode(int32_t destinationUniqueID, uint64_t hostTime, const uint8_t *raw, size_t rawLength, uint8_t *out);

/// The source the copies go out on (the driver's private entity, or the harness's virtual source). 0 stops copying.
void MxSpySetSource(MIDIEndpointRef source);
MIDIEndpointRef MxSpyGetSource(void);

/// Whether anyone is connected to the spy source (the server says so through the driver's EnableSource).
void MxSpySetListening(int listening);

/// Copies one outgoing packet list (the driver's Monitor call) onto the spy source. Safe on the realtime thread.
void MxSpyForwardPacketList(MIDIEndpointRef destination, const MIDIPacketList *packetList);

#ifdef __cplusplus
}
#endif

#endif /* MxSpyCore_h */
