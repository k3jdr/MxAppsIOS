//
//  MxSpyDriver.c — MxMidiPRO Spy
//
//  A version 2 CoreMIDI driver whose only job is MIDIDriverEnableMonitoring: the MIDI server then calls Monitor()
//  with every packet any app (Logic Pro) sends to any destination (a USB device). Those copies go out on a private
//  source — hidden from Logic Pro and every other app — that MxMidiPRO connects to.
//
//  It lives in ~/Library/Audio/MIDI Drivers (MxMidiPRO installs it there) and is loaded by the MIDI server, which is
//  sandboxed: that is why the copies travel back through CoreMIDI rather than a socket or Mach port of our own.
//

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreMIDI/CoreMIDI.h>
#include <CoreMIDI/MIDIDriver.h>
#include <os/log.h>
#include <stdlib.h>

#include "MxSpyCore.h"

// What the driver does when the MIDI server loads it, for troubleshooting:
//     log show --last 10m --predicate 'subsystem == "com.k3jdr.MxMidiPRO.SpyDriver"'
static os_log_t SpyLog(void) {
    static os_log_t log = NULL;
    if (log == NULL) log = os_log_create("com.k3jdr.MxMidiPRO.SpyDriver", "driver");
    return log;
}

// 2177A4CC-5C78-4A43-939B-A3DCA2A524D1 — the factory named in SpyDriver-Info.plist.
#define kMxSpyFactoryID CFUUIDGetConstantUUIDWithBytes(NULL, 0x21, 0x77, 0xA4, 0xCC, 0x5C, 0x78, 0x4A, 0x43, \
                                                       0x93, 0x9B, 0xA3, 0xDC, 0xA2, 0xA5, 0x24, 0xD1)

typedef struct {
    MIDIDriverInterface *interface;   // first, so a MxSpyDriver * is a MIDIDriverRef
    CFUUIDRef factoryID;
    UInt32 refCount;
    MIDIDeviceRef device;
} MxSpyDriver;

static HRESULT SpyQueryInterface(void *self, REFIID iid, LPVOID *ppv);
static ULONG SpyAddRef(void *self);
static ULONG SpyRelease(void *self);
static OSStatus SpyFindDevices(MIDIDriverRef self, MIDIDeviceListRef devices);
static OSStatus SpyStart(MIDIDriverRef self, MIDIDeviceListRef devices);
static OSStatus SpyStop(MIDIDriverRef self);
static OSStatus SpyConfigure(MIDIDriverRef self, MIDIDeviceRef device);
static OSStatus SpySend(MIDIDriverRef self, const MIDIPacketList *packets, void *refCon1, void *refCon2);
static OSStatus SpyEnableSource(MIDIDriverRef self, MIDIEndpointRef source, Boolean enabled);
static OSStatus SpyFlush(MIDIDriverRef self, MIDIEndpointRef destination, void *refCon1, void *refCon2);
static OSStatus SpyMonitor(MIDIDriverRef self, MIDIEndpointRef destination, const MIDIPacketList *packets);

static MIDIDriverInterface gSpyInterface = {
    NULL,
    SpyQueryInterface,
    SpyAddRef,
    SpyRelease,
    SpyFindDevices,
    SpyStart,
    SpyStop,
    SpyConfigure,
    SpySend,
    SpyEnableSource,
    SpyFlush,
    SpyMonitor,
    NULL,   // SendPackets (version 3 only)
    NULL,   // MonitorEvents (version 3 only)
};

__attribute__((visibility("default")))
void *MxMidiSpyFactory(CFAllocatorRef allocator, CFUUIDRef typeID);

void *MxMidiSpyFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;
    os_log(SpyLog(), "factory called");
    if (!CFEqual(typeID, kMIDIDriverTypeID)) return NULL;
    MxSpyDriver *driver = calloc(1, sizeof(MxSpyDriver));
    if (driver == NULL) return NULL;
    driver->interface = &gSpyInterface;
    driver->factoryID = CFRetain(kMxSpyFactoryID);
    driver->refCount = 1;
    CFPlugInAddInstanceForFactory(driver->factoryID);
    return driver;
}

static HRESULT SpyQueryInterface(void *self, REFIID iid, LPVOID *ppv) {
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
    HRESULT result = E_NOINTERFACE;
    *ppv = NULL;
    // Version 2 is the interface with Monitor(); the server falls back to it when version 3 is refused.
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kMIDIDriverInterface2ID)) {
        SpyAddRef(self);
        *ppv = self;
        result = S_OK;
    }
    CFStringRef text = CFUUIDCreateString(kCFAllocatorDefault, requested);
    char name[64] = "";
    if (text != NULL) { CFStringGetCString(text, name, sizeof(name), kCFStringEncodingASCII); CFRelease(text); }
    os_log(SpyLog(), "interface %{public}s requested: %{public}s", name, result == S_OK ? "given" : "refused");
    CFRelease(requested);
    return result;
}

static ULONG SpyAddRef(void *self) {
    MxSpyDriver *driver = (MxSpyDriver *)self;
    return ++driver->refCount;
}

static ULONG SpyRelease(void *self) {
    MxSpyDriver *driver = (MxSpyDriver *)self;
    if (driver->refCount > 1) return --driver->refCount;
    CFPlugInRemoveInstanceForFactory(driver->factoryID);
    CFRelease(driver->factoryID);
    free(driver);
    return 0;
}

static OSStatus SpyFindDevices(MIDIDriverRef self, MIDIDeviceListRef devices) {
    (void)self; (void)devices;
    return noErr;   // version 1 only
}

// Only the source is private: that hides it from Logic Pro's inputs. A private device or entity disappears from the
// device list altogether on macOS 27, so they stay visible (Audio MIDI Setup shows "MxMidiPRO Spy" with no ports).
static void SetPrivate(MIDIObjectRef object, int isPrivate) {
    if (object != 0) MIDIObjectSetIntegerProperty(object, kMIDIPropertyPrivate, isPrivate);
}

static OSStatus SpyStart(MIDIDriverRef self, MIDIDeviceListRef devices) {
    MxSpyDriver *driver = (MxSpyDriver *)self;
    MIDIDeviceRef device = 0;

    // The device persists in the MIDI setup between runs; keep the first and drop any duplicates.
    ItemCount count = MIDIDeviceListGetNumberOfDevices(devices);
    for (ItemCount i = 0; i < count; i++) {
        MIDIDeviceRef candidate = MIDIDeviceListGetDevice(devices, i);
        if (device == 0) device = candidate;
        else MIDISetupRemoveDevice(candidate);
    }

    os_log(SpyLog(), "start: %lu device(s) from the last run", (unsigned long)count);

    if (device == 0) {
        OSStatus status = MIDIDeviceCreate(self, CFSTR("MxMidiPRO Spy"), CFSTR("MxAppsIOS"), CFSTR("MxMidiPRO Spy"),
                                           &device);
        if (status != noErr) {
            os_log_error(SpyLog(), "start: MIDIDeviceCreate failed (%d)", (int)status);
            return status;
        }
        MIDIEntityRef entity = 0;
        OSStatus entityStatus = MIDIDeviceNewEntity(device, CFSTR("Outgoing MIDI"), kMIDIProtocol_1_0, false, 1, 0,
                                                    &entity);
        OSStatus addStatus = MIDISetupAddDevice(device);
        os_log(SpyLog(), "start: created the device (entity %d, add %d)", (int)entityStatus, (int)addStatus);
    }

    SetPrivate(device, 0);
    MIDIObjectSetIntegerProperty(device, kMIDIPropertyOffline, 0);

    MIDIEntityRef entity = MIDIDeviceGetNumberOfEntities(device) > 0 ? MIDIDeviceGetEntity(device, 0) : 0;
    if (entity == 0) {
        MIDIDeviceNewEntity(device, CFSTR("Outgoing MIDI"), kMIDIProtocol_1_0, false, 1, 0, &entity);
    }
    SetPrivate(entity, 0);
    MIDIEndpointRef source = (entity != 0 && MIDIEntityGetNumberOfSources(entity) > 0)
        ? MIDIEntityGetSource(entity, 0) : 0;
    SetPrivate(source, 1);

    // A fixed unique ID, so MxMidiPRO can find the private source.
    SInt32 uniqueID = 0;
    OSStatus idStatus = noErr;
    if (source != 0) {
        MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID);
        if (uniqueID != MXSPY_SOURCE_UNIQUE_ID) {
            idStatus = MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, MXSPY_SOURCE_UNIQUE_ID);
        }
        MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID);
    }

    driver->device = device;
    MxSpySetSource(source);
    OSStatus monitoring = MIDIDriverEnableMonitoring(self, true);
    os_log(SpyLog(), "start: source %u, unique ID %d (set %d), monitoring %d", (unsigned)source, (int)uniqueID,
           (int)idStatus, (int)monitoring);
    return monitoring;
}

static OSStatus SpyStop(MIDIDriverRef self) {
    MIDIDriverEnableMonitoring(self, false);
    MxSpySetSource(0);
    return noErr;
}

static OSStatus SpyConfigure(MIDIDriverRef self, MIDIDeviceRef device) {
    (void)self; (void)device;
    return noErr;
}

static OSStatus SpySend(MIDIDriverRef self, const MIDIPacketList *packets, void *refCon1, void *refCon2) {
    (void)self; (void)packets; (void)refCon1; (void)refCon2;
    return noErr;   // the spy has no destinations
}

static OSStatus SpyEnableSource(MIDIDriverRef self, MIDIEndpointRef source, Boolean enabled) {
    (void)self;
    if (source == MxSpyGetSource()) MxSpySetListening(enabled ? 1 : 0);
    return noErr;
}

static OSStatus SpyFlush(MIDIDriverRef self, MIDIEndpointRef destination, void *refCon1, void *refCon2) {
    (void)self; (void)destination; (void)refCon1; (void)refCon2;
    return noErr;
}

static OSStatus SpyMonitor(MIDIDriverRef self, MIDIEndpointRef destination, const MIDIPacketList *packets) {
    (void)self;
    MxSpyForwardPacketList(destination, packets);
    return noErr;
}
