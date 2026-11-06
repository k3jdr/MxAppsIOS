//
//  MxSpyCore.c — MxMidiPRO Spy
//
//  Monitor() runs on the MIDI server's realtime I/O thread, so this file allocates nothing: the spy message and
//  its packet list are built on the stack, and destination unique IDs come from a small cache that is refreshed
//  every few seconds (endpoint refs can be reused after a device or app port goes away).
//

#include "MxSpyCore.h"

#include <mach/mach_time.h>
#include <os/lock.h>
#include <string.h>

// MIDIPacketList is what Monitor() is handed, and MIDIReceived is its counterpart; both are deprecated in favour
// of MIDIEventList but are what a version 2 driver works with.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static MIDIEndpointRef gSource = 0;
static volatile int gListening = 1;

#define MXSPY_CACHE_SIZE 128
typedef struct { MIDIEndpointRef ref; int32_t uniqueID; } MxSpyCacheEntry;
static MxSpyCacheEntry gCache[MXSPY_CACHE_SIZE];
static int gCacheCount = 0;
static uint64_t gCacheStarted = 0;
static os_unfair_lock gCacheLock = OS_UNFAIR_LOCK_INIT;

void MxSpySetSource(MIDIEndpointRef source) { gSource = source; }
MIDIEndpointRef MxSpyGetSource(void) { return gSource; }
void MxSpySetListening(int listening) { gListening = listening; }

static uint64_t SecondsToHostTicks(double seconds) {
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    return (uint64_t)(seconds * 1e9 * (double)base.denom / (double)base.numer);
}

static int32_t UniqueIDFor(MIDIEndpointRef destination) {
    static uint64_t refreshTicks = 0;
    if (refreshTicks == 0) refreshTicks = SecondsToHostTicks(5.0);

    uint64_t now = mach_absolute_time();
    int32_t uniqueID = 0;
    int found = 0;

    os_unfair_lock_lock(&gCacheLock);
    if (now - gCacheStarted > refreshTicks) { gCacheCount = 0; gCacheStarted = now; }
    for (int i = 0; i < gCacheCount; i++) {
        if (gCache[i].ref == destination) { uniqueID = gCache[i].uniqueID; found = 1; break; }
    }
    os_unfair_lock_unlock(&gCacheLock);
    if (found) return uniqueID;

    SInt32 value = 0;
    if (MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &value) != noErr) return 0;

    os_unfair_lock_lock(&gCacheLock);
    if (gCacheCount == MXSPY_CACHE_SIZE) gCacheCount = 0;
    gCache[gCacheCount].ref = destination;
    gCache[gCacheCount].uniqueID = value;
    gCacheCount++;
    os_unfair_lock_unlock(&gCacheLock);
    return value;
}

static uint8_t *Put7BitGroups(uint8_t *p, uint64_t value, int groups) {
    for (int i = 0; i < groups; i++) { *p++ = (uint8_t)(value & 0x7F); value >>= 7; }
    return p;
}

size_t MxSpyEncode(int32_t destinationUniqueID, uint64_t hostTime, const uint8_t *raw, size_t rawLength, uint8_t *out) {
    uint8_t *p = out;
    *p++ = 0xF0;
    *p++ = MXSPY_SYSEX_ID;
    *p++ = MXSPY_TAG_1;
    *p++ = MXSPY_TAG_2;
    *p++ = MXSPY_VERSION;
    p = Put7BitGroups(p, (uint32_t)destinationUniqueID, 5);
    p = Put7BitGroups(p, hostTime, 10);
    for (size_t i = 0; i < rawLength; i += 7) {
        size_t n = rawLength - i < 7 ? rawLength - i : 7;
        uint8_t high = 0;
        for (size_t j = 0; j < n; j++) if (raw[i + j] & 0x80) high |= (uint8_t)(1u << j);
        *p++ = high;
        for (size_t j = 0; j < n; j++) *p++ = raw[i + j] & 0x7F;
    }
    *p++ = 0xF7;
    return (size_t)(p - out);
}

void MxSpyForwardPacketList(MIDIEndpointRef destination, const MIDIPacketList *packetList) {
    MIDIEndpointRef source = gSource;
    if (source == 0 || !gListening || packetList == NULL || packetList->numPackets == 0) return;

    int32_t uniqueID = UniqueIDFor(destination);
    uint8_t encoded[MXSPY_HEADER_BYTES + MXSPY_MAX_CHUNK + (MXSPY_MAX_CHUNK + 6) / 7 + 1];
    Byte listBuffer[sizeof(MIDIPacketList) + sizeof(encoded) + 64];

    const MIDIPacket *packet = &packetList->packet[0];
    for (UInt32 i = 0; i < packetList->numPackets; i++) {
        uint64_t when = packet->timeStamp != 0 ? packet->timeStamp : mach_absolute_time();
        uint32_t length = packet->length;
        for (uint32_t offset = 0; offset < length; ) {
            uint32_t chunk = length - offset;
            if (chunk > MXSPY_MAX_CHUNK) chunk = MXSPY_MAX_CHUNK;
            size_t size = MxSpyEncode(uniqueID, when, packet->data + offset, chunk, encoded);
            MIDIPacketList *out = (MIDIPacketList *)listBuffer;
            MIDIPacket *current = MIDIPacketListInit(out);
            current = MIDIPacketListAdd(out, sizeof(listBuffer), current, 0, size, encoded);
            if (current != NULL) MIDIReceived(source, out);
            offset += chunk;
        }
        packet = MIDIPacketNext(packet);
    }
}
