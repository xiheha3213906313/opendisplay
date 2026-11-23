/* SPDX-License-Identifier: GPL-3.0-only
 * AudioServerPlugIn interfaces and clock model adapted from Apple's NullAudio.
 * Copyright © 2024 Apple Inc. (see APPLE-LICENSE.txt)
 * WriteMix loopback adapted from BlackHole. See Loopback.h.
 */
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/HostTime.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <unistd.h>
#include "Loopback.h"

#ifndef OD_APP_ID
#define OD_APP_ID "com.peetzweg.opensidecar.mac.debug"
#endif
#ifndef OD_BUNDLE_ID
#define OD_BUNDLE_ID "app.opendisplay.audio.driver.debug"
#endif

enum {
    ODVersionProperty = 'odvr', ODRegistryProperty = 'odrg', ODPCMProperty = 'odpc',
    ODProtocolVersion = 1, ODDeviceLimit = 16, ODClockPeriod = 512,
    ODStreamOffset = 1, ODVolumeOffset = 2, ODMuteOffset = 3, ODObjectStride = 4
};

typedef struct {
    _Atomic AudioObjectID id;
    _Atomic bool visible;
    _Atomic bool streamActive;
    CFStringRef uid;
    CFStringRef name;
    _Atomic uint32_t clients;
    _Atomic uint64_t anchor;
    _Atomic uint64_t seed;
    Float32 volume;
    UInt32 mute;
    ODRing pcm;
} ODDevice;

static AudioServerPlugInHostRef host;
static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interfacePointer = &interface;
static AudioServerPlugInDriverRef driver = &interfacePointer;
static _Atomic ULONG references = 1;
static pthread_mutex_t stateLock = PTHREAD_MUTEX_INITIALIZER;
static ODDevice devices[ODDeviceLimit];
static AudioObjectID nextID = 16;
static pid_t registryOwner;
static uint64_t renewTime;
static dispatch_source_t expiryTimer;
static double ticksPerFrame;
static uint64_t leaseTicks;
static uint64_t maxAgeTicks;
static const AudioObjectPropertyAddress deviceListChanges[] = {
    {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}
};

static ODDevice *findDevice(AudioObjectID id) {
    if (id < 16) return NULL;
    const AudioObjectID base = id - id % ODObjectStride;
    for (size_t i = 0; i < ODDeviceLimit; ++i) {
        if (atomic_load(&devices[i].id) == base) return &devices[i];
    }
    return NULL;
}

static void notifyDevices(void) {
    // Let the registry setter return before the host discovers new objects.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        host->PropertiesChanged(host, kAudioObjectPlugInObject, 2, deviceListChanges);
    });
}

static void retireDevice(ODDevice *device) {
    atomic_store(&device->visible, false);
    CFRelease(device->name);
    device->name = NULL;
}

static ODDevice *availableSlot(CFStringRef uid) {
    ODDevice *fallback = NULL;
    for (size_t i = 0; i < ODDeviceLimit; ++i) {
        ODDevice *device = &devices[i];
        if (atomic_load(&device->visible) || atomic_load(&device->clients)) continue;
        if (device->uid && CFEqual(device->uid, uid)) return device;
        if (!fallback || (fallback->uid && !device->uid)) fallback = device;
    }
    return fallback;
}

static bool expireOwner(uint64_t now) {
    if (!registryOwner || now - renewTime < leaseTicks) return false;
    bool changed = false;
    for (size_t i = 0; i < ODDeviceLimit; ++i) {
        if (atomic_load(&devices[i].visible)) {
            retireDevice(&devices[i]);
            changed = true;
        }
    }
    registryOwner = 0;
    return changed;
}

static ULONG retain(void *self) {
    return self == driver ? atomic_fetch_add(&references, 1) + 1 : 0;
}
static ULONG release(void *self) {
    return self == driver ? atomic_fetch_sub(&references, 1) - 1 : 0;
}
static HRESULT query(void *self, REFIID uuid, LPVOID *result) {
    if (self != driver || !result) return E_POINTER;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    const bool valid = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    *result = valid ? driver : NULL;
    if (valid) retain(self);
    return valid ? S_OK : E_NOINTERFACE;
}

void *OpenDisplayAudio_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? driver : NULL;
}

static OSStatus initialize(AudioServerPlugInDriverRef self, AudioServerPlugInHostRef server) {
    if (self != driver || !server) return kAudioHardwareIllegalOperationError;
    host = server;
    ticksPerFrame = AudioGetHostClockFrequency() / ODSampleRate;
    leaseTicks = AudioConvertNanosToHostTime(4ull * 1000000000ull);
    maxAgeTicks = AudioConvertNanosToHostTime(80ull * 1000000ull);
    expiryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                         dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(expiryTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                              NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(expiryTimer, ^{
        pthread_mutex_lock(&stateLock);
        const bool changed = expireOwner(AudioGetCurrentHostTime());
        pthread_mutex_unlock(&stateLock);
        if (changed) notifyDevices();
    });
    dispatch_resume(expiryTimer);
    return noErr;
}

static bool canPublish(pid_t pid) {
#ifdef OD_HAL_TEST
    return pid == getpid();
#else
    if (pid <= 0) return false;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *keys[] = {kSecGuestAttributePid};
    const void *values[] = {number};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef client = NULL;
    SecRequirementRef requirement = NULL;
#ifdef OD_TEAM_ID
    CFStringRef rule = CFSTR("anchor apple generic and identifier \"" OD_APP_ID
                            "\" and certificate leaf[subject.OU] = \"" OD_TEAM_ID "\"");
#else
    // The local, ad-hoc Debug build is a separate plug-in and app identity.
    CFStringRef rule = CFSTR("identifier \"" OD_APP_ID "\"");
#endif
    const bool allowed = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &client) == errSecSuccess
        && SecRequirementCreateWithString(rule, kSecCSDefaultFlags, &requirement) == errSecSuccess
        && SecCodeCheckValidity(client, kSecCSDefaultFlags, requirement) == errSecSuccess;
    if (requirement) CFRelease(requirement);
    if (client) CFRelease(client);
    CFRelease(attributes);
    CFRelease(number);
    return allowed;
#endif
}

static OSStatus replaceRegistry(pid_t pid, CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFArrayGetTypeID()) return kAudioHardwareIllegalOperationError;
    CFArrayRef registry = value;
    const CFIndex count = CFArrayGetCount(registry);
    if (count > ODDeviceLimit) return kAudioHardwareIllegalOperationError;
    CFStringRef uids[ODDeviceLimit];
    CFStringRef names[ODDeviceLimit];
    for (CFIndex i = 0; i < count; ++i) {
        CFTypeRef entry = CFArrayGetValueAtIndex(registry, i);
        if (CFGetTypeID(entry) != CFDictionaryGetTypeID()) return kAudioHardwareIllegalOperationError;
        uids[i] = CFDictionaryGetValue(entry, CFSTR("uid"));
        names[i] = CFDictionaryGetValue(entry, CFSTR("name"));
        if (!uids[i] || CFGetTypeID(uids[i]) != CFStringGetTypeID() ||
            !names[i] || CFGetTypeID(names[i]) != CFStringGetTypeID() ||
            !CFStringHasPrefix(uids[i], CFSTR(OD_BUNDLE_ID ".")) ||
            CFStringGetLength(uids[i]) > 100 || CFStringGetLength(names[i]) > 100 ||
            !CFStringGetLength(names[i])) return kAudioHardwareIllegalOperationError;
        for (CFIndex j = 0; j < i; ++j) {
            if (CFEqual(uids[j], uids[i])) return kAudioHardwareIllegalOperationError;
        }
    }

    pthread_mutex_lock(&stateLock);
    const uint64_t now = AudioGetCurrentHostTime();
    bool changed = expireOwner(now);
    OSStatus result = noErr;
    if ((registryOwner && registryOwner != pid) || (!registryOwner && !canPublish(pid))) {
        result = kAudioDevicePermissionsError;
        goto done;
    }

    ODDevice *existing[ODDeviceLimit] = {0};
    size_t freeCount = 0;
    for (size_t i = 0; i < ODDeviceLimit; ++i) {
        ODDevice *device = &devices[i];
        if (atomic_load(&device->visible)) {
            for (CFIndex j = 0; j < count; ++j) {
                if (CFEqual(device->uid, uids[j])) existing[j] = device;
            }
        } else if (!atomic_load(&device->clients)) {
            ++freeCount;
        }
    }
    size_t additions = 0;
    for (CFIndex i = 0; i < count; ++i) if (!existing[i]) ++additions;
    if (additions > freeCount || nextID > UINT32_MAX - additions * ODObjectStride) {
        result = kAudioHardwareIllegalOperationError;
        goto done;
    }
    for (size_t i = 0; i < ODDeviceLimit; ++i) {
        ODDevice *device = &devices[i];
        if (!atomic_load(&device->visible)) continue;
        bool keep = false;
        for (CFIndex j = 0; j < count; ++j) if (existing[j] == device) keep = true;
        if (!keep) {
            retireDevice(device);
            changed = true;
        }
    }
    for (CFIndex i = 0; i < count; ++i) {
        if (existing[i]) continue;
        ODDevice *device = availableSlot(uids[i]);
        // Reserved by the capacity check above on this same lock.
        if (!device) { result = kAudioHardwareIllegalOperationError; goto done; }
        if (!device->uid || !CFEqual(device->uid, uids[i])) {
            if (device->uid) CFRelease(device->uid);
            device->uid = CFRetain(uids[i]);
            device->volume = 1;
            device->mute = 0;
        }
        device->name = CFRetain(names[i]);
        atomic_store(&device->streamActive, true);
        ODRingReset(&device->pcm);
        atomic_store(&device->anchor, now);
        atomic_store(&device->seed, 1);
        atomic_store(&device->id, nextID);
        nextID += ODObjectStride;
        atomic_store(&device->visible, true);
        changed = true;
    }
    registryOwner = count ? pid : 0;
    renewTime = now;
done:
    pthread_mutex_unlock(&stateLock);
    if (changed) notifyDevices();
    return result;
}

static OSStatus copyValue(UInt32 capacity, UInt32 *size, void *out, const void *value, UInt32 bytes) {
    if (out && capacity < bytes) return kAudioHardwareBadPropertySizeError;
    if (out && bytes) memcpy(out, value, bytes);
    *size = bytes;
    return noErr;
}

static OSStatus copyCF(UInt32 capacity, UInt32 *size, void *out, CFTypeRef value) {
    if (out && capacity < sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError;
    *size = sizeof(CFTypeRef);
    if (out) *(CFTypeRef *)out = CFRetain(value);
    return noErr;
}

static const AudioStreamBasicDescription stereoFormat = {
    .mSampleRate = ODSampleRate, .mFormatID = kAudioFormatLinearPCM,
    .mFormatFlags = kAudioFormatFlagsNativeFloatPacked, .mBytesPerPacket = 8,
    .mFramesPerPacket = 1, .mBytesPerFrame = 8, .mChannelsPerFrame = 2, .mBitsPerChannel = 32
};

// Size, presence and read share the same property table. For a size query
// out is NULL, so names aren't retained and the PCM cursor is untouched.
static OSStatus property(AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress *address,
                         UInt32 qualifierSize, const void *qualifier, UInt32 capacity, UInt32 *size, void *out) {
#define VALUE(type, expression) do { const type value = (expression); return copyValue(capacity, size, out, &value, sizeof(value)); } while (0)
#define OBJECT(value) return copyCF(capacity, size, out, (value))
    const AudioObjectPropertySelector selector = address->mSelector;
    const AudioObjectPropertyScope scope = address->mScope;
    if (id == kAudioObjectPlugInObject) {
        switch (selector) {
        case kAudioObjectPropertyBaseClass: VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: OBJECT(CFSTR("OpenDisplay"));
        case kAudioPlugInPropertyBundleID: OBJECT(CFSTR(OD_BUNDLE_ID));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID list[ODDeviceLimit];
            UInt32 count = 0;
            for (size_t i = 0; i < ODDeviceLimit; ++i) {
                if (atomic_load(&devices[i].visible)) list[count++] = atomic_load(&devices[i].id);
            }
            return copyValue(capacity, size, out, list, count * sizeof(list[0]));
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID found = kAudioObjectUnknown;
            if (qualifier && qualifierSize == sizeof(CFStringRef)) {
                const CFStringRef uid = *(const CFStringRef *)qualifier;
                for (size_t i = 0; i < ODDeviceLimit; ++i) {
                    if (uid && atomic_load(&devices[i].visible) && CFEqual(uid, devices[i].uid)) {
                        found = atomic_load(&devices[i].id);
                    }
                }
            }
            VALUE(AudioObjectID, found);
        }
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList: return copyValue(capacity, size, out, NULL, 0);
        case kAudioObjectPropertyCustomPropertyInfoList: {
            const AudioServerPlugInCustomPropertyInfo info[] = {
                {ODVersionProperty, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone},
                {ODRegistryProperty, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone}
            };
            return copyValue(capacity, size, out, info, sizeof(info));
        }
        case ODVersionProperty:
            if (!out) { *size = sizeof(CFTypeRef); return noErr; }
            else {
                const int version = ODProtocolVersion;
                CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &version);
                const OSStatus status = copyCF(capacity, size, out, value);
                CFRelease(value);
                return status;
            }
        case ODRegistryProperty:
            if (!out) { *size = sizeof(CFTypeRef); return noErr; }
            else {
                CFArrayRef empty = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
                const OSStatus status = copyCF(capacity, size, out, empty);
                CFRelease(empty);
                return status;
            }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    ODDevice *device = findDevice(id);
    if (!device || !atomic_load(&device->visible)) return kAudioHardwareBadObjectError;
    const AudioObjectID base = atomic_load(&device->id);
    const UInt32 offset = id - base;
    if (selector == kAudioObjectPropertyOwner) VALUE(AudioObjectID, offset ? base : kAudioObjectPlugInObject);
    if (offset && selector == kAudioObjectPropertyOwnedObjects) return copyValue(capacity, size, out, NULL, 0);
    if (offset == ODStreamOffset) {
        switch (selector) {
        case kAudioObjectPropertyBaseClass: VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioStreamPropertyIsActive: VALUE(UInt32, atomic_load(&device->streamActive));
        case kAudioStreamPropertyDirection: VALUE(UInt32, 0);
        case kAudioStreamPropertyTerminalType: VALUE(UInt32, kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: VALUE(AudioStreamBasicDescription, stereoFormat);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            const AudioStreamRangedDescription range = {stereoFormat, {ODSampleRate, ODSampleRate}};
            VALUE(AudioStreamRangedDescription, range);
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }
    if (offset == ODVolumeOffset || offset == ODMuteOffset) {
        const bool volume = offset == ODVolumeOffset;
        switch (selector) {
        case kAudioObjectPropertyClass: VALUE(AudioClassID, volume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
        case kAudioObjectPropertyBaseClass: VALUE(AudioClassID, volume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
        case kAudioControlPropertyScope: VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement: VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            if (!volume) return kAudioHardwareUnknownPropertyError;
            if (selector == kAudioLevelControlPropertyDecibelRange) {
                const AudioValueRange range = {-96, 0};
                VALUE(AudioValueRange, range);
            }
            Float32 value = device->volume;
            if (selector == kAudioLevelControlPropertyConvertScalarToDecibels ||
                selector == kAudioLevelControlPropertyConvertDecibelsToScalar) {
                if (out && capacity < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                if (out) value = *(Float32 *)out;
            }
            if (selector == kAudioLevelControlPropertyConvertDecibelsToScalar) {
                value = powf(10, fmaxf(-96, fminf(0, value)) / 20);
            } else if (selector != kAudioLevelControlPropertyScalarValue) {
                value = 20 * log10f(fmaxf(powf(10, -96.f / 20), fminf(1, value)));
            }
            return copyValue(capacity, size, out, &value, sizeof(value));
        }
        case kAudioBooleanControlPropertyValue:
            if (volume) return kAudioHardwareUnknownPropertyError;
            VALUE(UInt32, device->mute);
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    switch (selector) {
    case kAudioObjectPropertyBaseClass: VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: VALUE(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyName: OBJECT(device->name);
    case kAudioObjectPropertyManufacturer: OBJECT(CFSTR("OpenDisplay"));
    case kAudioDevicePropertyDeviceUID: OBJECT(device->uid);
    case kAudioDevicePropertyModelUID: OBJECT(CFSTR(OD_BUNDLE_ID ".android-output"));
    case kAudioDevicePropertyTransportType: VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: VALUE(AudioObjectID, base);
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset: VALUE(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: VALUE(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: VALUE(UInt32, atomic_load(&device->clients) != 0);
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: VALUE(UInt32, scope != kAudioObjectPropertyScopeInput);
    case kAudioDevicePropertyNominalSampleRate: VALUE(Float64, ODSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        const AudioValueRange range = {ODSampleRate, ODSampleRate};
        VALUE(AudioValueRange, range);
    }
    case kAudioObjectPropertyOwnedObjects:
    case kAudioObjectPropertyControlList:
    case kAudioDevicePropertyStreams: {
        const AudioObjectID children[] = {base + ODStreamOffset, base + ODVolumeOffset, base + ODMuteOffset};
        if (scope == kAudioObjectPropertyScopeInput) return copyValue(capacity, size, out, NULL, 0);
        if (selector == kAudioDevicePropertyStreams) VALUE(AudioObjectID, children[0]);
        if (selector == kAudioObjectPropertyControlList) return copyValue(capacity, size, out, children + 1, 2 * sizeof(AudioObjectID));
        return copyValue(capacity, size, out, children, sizeof(children));
    }
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (scope != kAudioObjectPropertyScopeOutput) return kAudioHardwareUnknownPropertyError;
        const UInt32 channels[] = {1, 2};
        return copyValue(capacity, size, out, channels, sizeof(channels));
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        if (scope != kAudioObjectPropertyScopeOutput) return kAudioHardwareUnknownPropertyError;
        const AudioChannelLayout layout = {.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo};
        return copyValue(capacity, size, out, &layout, offsetof(AudioChannelLayout, mChannelDescriptions));
    }
    case kAudioDevicePropertyZeroTimeStampPeriod: VALUE(UInt32, ODClockPeriod);
    case kAudioObjectPropertyCustomPropertyInfoList: {
        const AudioServerPlugInCustomPropertyInfo info = {
            ODPCMProperty, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone
        };
        VALUE(AudioServerPlugInCustomPropertyInfo, info);
    }
    case ODPCMProperty: {
        if (!out) { *size = sizeof(CFTypeRef); return noErr; }
        if (pid <= 0 || pid != registryOwner) return kAudioDevicePermissionsError;
        if (capacity < sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError;
        const uint64_t now = AudioGetCurrentHostTime();
        float samples[ODMaxFrames * ODChannels];
        const uint32_t frames = ODRingRead(&device->pcm, samples, now > maxAgeTicks ? now - maxAgeTicks : 0);
        const float gain = device->mute ? 0 : device->volume;
        for (uint32_t i = 0; i < frames * ODChannels; ++i) samples[i] *= gain;
        *(CFDataRef *)out = CFDataCreate(NULL, (const UInt8 *)samples, frames * ODChannels * sizeof(float));
        *size = sizeof(CFTypeRef);
        return *(CFDataRef *)out ? noErr : kAudioHardwareUnspecifiedError;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
#undef OBJECT
#undef VALUE
}

static Boolean hasProperty(AudioServerPlugInDriverRef self, AudioObjectID id, pid_t pid,
                           const AudioObjectPropertyAddress *address) {
    if (self != driver || !address) return false;
    UInt32 size = 0;
    pthread_mutex_lock(&stateLock);
    const OSStatus result = property(id, pid, address, 0, NULL, 0, &size, NULL);
    pthread_mutex_unlock(&stateLock);
    return result == noErr;
}

static OSStatus isSettable(AudioServerPlugInDriverRef self, AudioObjectID id, pid_t pid,
                           const AudioObjectPropertyAddress *address, Boolean *settable) {
    if (!settable || !hasProperty(self, id, pid, address)) return kAudioHardwareUnknownPropertyError;
    switch (address->mSelector) {
    case ODRegistryProperty:
    case kAudioLevelControlPropertyScalarValue:
    case kAudioLevelControlPropertyDecibelValue:
    case kAudioBooleanControlPropertyValue:
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioStreamPropertyPhysicalFormat:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyIsActive: *settable = true; break;
    default: *settable = false;
    }
    return noErr;
}

static OSStatus getSize(AudioServerPlugInDriverRef self, AudioObjectID id, pid_t pid,
                        const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 *size) {
    if (self != driver || !address || !size) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&stateLock);
    const OSStatus result = property(id, pid, address, qualifierSize, qualifier, 0, size, NULL);
    pthread_mutex_unlock(&stateLock);
    return result;
}

static OSStatus getData(AudioServerPlugInDriverRef self, AudioObjectID id, pid_t pid,
                        const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                        UInt32 capacity, UInt32 *size, void *out) {
    if (self != driver || !address || !size || !out) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&stateLock);
    const OSStatus result = property(id, pid, address, qualifierSize, qualifier, capacity, size, out);
    pthread_mutex_unlock(&stateLock);
    return result;
}

static OSStatus setData(AudioServerPlugInDriverRef self, AudioObjectID id, pid_t pid,
                        const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                        UInt32 size, const void *data) {
    if (self != driver || !address || !data) return kAudioHardwareIllegalOperationError;
    Boolean writable = false;
    if (isSettable(self, id, pid, address, &writable) != noErr || !writable) return kAudioHardwareUnknownPropertyError;
    if (id == kAudioObjectPlugInObject && address->mSelector == ODRegistryProperty) {
        if (size != sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError;
        return replaceRegistry(pid, *(const CFTypeRef *)data);
    }

    AudioObjectPropertyAddress changes[2] = {*address, *address};
    UInt32 changeCount = 0;
    OSStatus result = noErr;
    pthread_mutex_lock(&stateLock);
    ODDevice *device = findDevice(id);
    if (!device || !atomic_load(&device->visible)) {
        result = kAudioHardwareBadObjectError;
    } else {
        switch (address->mSelector) {
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
            if (size != sizeof(Float32)) result = kAudioHardwareBadPropertySizeError;
            else {
                float value = *(const Float32 *)data;
                if (!isfinite(value)) { result = kAudioHardwareIllegalOperationError; break; }
                if (address->mSelector == kAudioLevelControlPropertyDecibelValue) value = powf(10, value / 20);
                device->volume = fmaxf(0, fminf(value, 1));
                changes[0].mSelector = kAudioLevelControlPropertyScalarValue;
                changes[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                changeCount = 2;
            }
            break;
        case kAudioBooleanControlPropertyValue:
            if (size != sizeof(UInt32)) result = kAudioHardwareBadPropertySizeError;
            else { device->mute = *(const UInt32 *)data != 0; changeCount = 1; }
            break;
        case kAudioDevicePropertyNominalSampleRate:
            if (size != sizeof(Float64) || *(const Float64 *)data != ODSampleRate) result = kAudioDeviceUnsupportedFormatError;
            break;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (size != sizeof(stereoFormat) || memcmp(data, &stereoFormat, sizeof(stereoFormat))) result = kAudioDeviceUnsupportedFormatError;
            break;
        case kAudioStreamPropertyIsActive:
            if (size != sizeof(UInt32)) result = kAudioHardwareBadPropertySizeError;
            else {
                const bool active = *(const UInt32 *)data != 0;
                if (atomic_exchange(&device->streamActive, active) != active) changeCount = 1;
            }
            break;
        default: result = kAudioHardwareUnknownPropertyError;
        }
    }
    pthread_mutex_unlock(&stateLock);
    if (changeCount) host->PropertiesChanged(host, id, changeCount, changes);
    return result;
}

static OSStatus createDevice(AudioServerPlugInDriverRef self, CFDictionaryRef description,
                             const AudioServerPlugInClientInfo *client, AudioObjectID *id) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus destroyDevice(AudioServerPlugInDriverRef self, AudioObjectID id) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus deviceClient(AudioServerPlugInDriverRef self, AudioObjectID id, const AudioServerPlugInClientInfo *client) {
    return findDevice(id) ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus deviceChange(AudioServerPlugInDriverRef self, AudioObjectID id, UInt64 action, void *info) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus startIO(AudioServerPlugInDriverRef self, AudioObjectID id, UInt32 client) {
    pthread_mutex_lock(&stateLock);
    ODDevice *device = findDevice(id);
    const bool live = device && atomic_load(&device->visible);
    if (live && atomic_fetch_add(&device->clients, 1) == 0) {
        ODRingReset(&device->pcm);
        atomic_store(&device->anchor, AudioGetCurrentHostTime());
        atomic_fetch_add(&device->seed, 1);
    }
    pthread_mutex_unlock(&stateLock);
    return live ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus stopIO(AudioServerPlugInDriverRef self, AudioObjectID id, UInt32 client) {
    pthread_mutex_lock(&stateLock);
    ODDevice *device = findDevice(id);
    if (device && atomic_load(&device->clients)) atomic_fetch_sub(&device->clients, 1);
    pthread_mutex_unlock(&stateLock);
    return device ? noErr : kAudioHardwareBadObjectError;
}

// Core Audio relates sample time to the host clock in timestamp periods.
// Derive the period from the anchor so an idle cycle never accumulates drift.
static OSStatus zeroTimestamp(AudioServerPlugInDriverRef self, AudioObjectID id, UInt32 client,
                              Float64 *sample, UInt64 *time, UInt64 *seed) {
    ODDevice *device = findDevice(id);
    if (!device) return kAudioHardwareBadObjectError;
    const uint64_t anchor = atomic_load(&device->anchor);
    const uint64_t now = AudioGetCurrentHostTime();
    const double ticksPerPeriod = ticksPerFrame * ODClockPeriod;
    const uint64_t period = now > anchor ? (uint64_t)((now - anchor) / ticksPerPeriod) : 0;
    *sample = (Float64)period * ODClockPeriod;
    *time = anchor + (uint64_t)(period * ticksPerPeriod);
    *seed = atomic_load(&device->seed);
    return noErr;
}

static OSStatus willIO(AudioServerPlugInDriverRef self, AudioObjectID id, UInt32 client, UInt32 operation,
                       Boolean *will, Boolean *inPlace) {
    if (!findDevice(id)) return kAudioHardwareBadObjectError;
    *will = operation == kAudioServerPlugInIOOperationWriteMix;
    *inPlace = true;
    return noErr;
}

static OSStatus ioBoundary(AudioServerPlugInDriverRef self, AudioObjectID id, UInt32 client,
                           UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    return findDevice(id) ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus doIO(AudioServerPlugInDriverRef self, AudioObjectID id, AudioObjectID stream,
                     UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle,
                     void *buffer, void *secondary) {
    ODDevice *device = findDevice(id);
    if (!device || stream != id + ODStreamOffset) return kAudioHardwareBadObjectError;
    if (operation == kAudioServerPlugInIOOperationWriteMix && buffer &&
        atomic_load(&device->visible) && atomic_load(&device->streamActive)) {
        ODRingWrite(&device->pcm, buffer, frames, AudioGetCurrentHostTime());
    }
    return noErr;
}

static AudioServerPlugInDriverInterface interface = {
    .QueryInterface = query, .AddRef = retain, .Release = release,
    .Initialize = initialize, .CreateDevice = createDevice, .DestroyDevice = destroyDevice,
    .AddDeviceClient = deviceClient, .RemoveDeviceClient = deviceClient,
    .PerformDeviceConfigurationChange = deviceChange, .AbortDeviceConfigurationChange = deviceChange,
    .HasProperty = hasProperty, .IsPropertySettable = isSettable, .GetPropertyDataSize = getSize,
    .GetPropertyData = getData, .SetPropertyData = setData,
    .StartIO = startIO, .StopIO = stopIO, .GetZeroTimeStamp = zeroTimestamp,
    .WillDoIOOperation = willIO, .BeginIOOperation = ioBoundary, .DoIOOperation = doIO, .EndIOOperation = ioBoundary
};
