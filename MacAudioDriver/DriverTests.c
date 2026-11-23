#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/HostTime.h>
#include <assert.h>
#include <stdio.h>
#include <stdatomic.h>
#include <unistd.h>

extern void *OpenDisplayAudio_Create(CFAllocatorRef, CFUUIDRef);

static _Atomic unsigned listChanges;
static OSStatus changed(AudioServerPlugInHostRef host, AudioObjectID id, UInt32 count,
                        const AudioObjectPropertyAddress *properties) {
    if (id == kAudioObjectPlugInObject) {
        assert(count == 2 && properties[0].mSelector == kAudioPlugInPropertyDeviceList);
        ++listChanges;
    }
    return noErr;
}

static const AudioServerPlugInHostInterface host = {.PropertiesChanged = changed};
static AudioServerPlugInDriverRef driver;
static const AudioObjectPropertyAddress registryAddress = {'odrg', kAudioObjectPropertyScopeGlobal, 0};
static const AudioObjectPropertyAddress pcmAddress = {'odpc', kAudioObjectPropertyScopeGlobal, 0};
static const AudioObjectPropertyAddress deviceListAddress = {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 0};

static CFDictionaryRef output(CFStringRef uid, CFStringRef name) {
    const void *keys[] = {CFSTR("uid"), CFSTR("name")};
    const void *values[] = {uid, name};
    return CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static OSStatus publish(const void **items, CFIndex count, pid_t pid) {
    CFArrayRef list = CFArrayCreate(NULL, items, count, &kCFTypeArrayCallBacks);
    OSStatus status = (*driver)->SetPropertyData(driver, kAudioObjectPlugInObject, pid,
        &registryAddress, 0, NULL, sizeof(list), &list);
    CFRelease(list);
    return status;
}

static UInt32 list(AudioObjectID *ids, UInt32 max) {
    UInt32 size = 0;
    assert((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, getpid(), &deviceListAddress,
                                      0, NULL, max * sizeof(*ids), &size, ids) == noErr);
    return size / sizeof(*ids);
}

static void writeMix(AudioObjectID device, float *packet, UInt32 frames) {
    AudioServerPlugInIOCycleInfo cycle = {0};
    assert((*driver)->DoIOOperation(driver, device, device + 1, 1,
        kAudioServerPlugInIOOperationWriteMix, frames, &cycle, packet, NULL) == noErr);
}

static CFDataRef readPCM(AudioObjectID device, pid_t pid, OSStatus expected) {
    CFDataRef data = NULL;
    UInt32 size = 0;
    assert((*driver)->GetPropertyData(driver, device, pid, &pcmAddress,
                                      0, NULL, sizeof(data), &size, &data) == expected);
    return data;
}

static void assertSamples(AudioObjectID device, const float *samples, size_t length) {
    CFDataRef data = readPCM(device, getpid(), noErr);
    assert((size_t)CFDataGetLength(data) == length * sizeof(*samples));
    if (length) assert(!memcmp(CFDataGetBytePtr(data), samples, length * sizeof(*samples)));
    CFRelease(data);
}

int main(void) {
    driver = OpenDisplayAudio_Create(NULL, kAudioServerPlugInTypeUUID);
    assert(driver && (*driver)->Initialize(driver, &host) == noErr);
    AudioObjectID ids[2] = {0};
    assert(list(ids, 2) == 0);
    const void *items[] = {
        output(CFSTR("app.opendisplay.audio.driver.debug.a"), CFSTR("First Android")),
        output(CFSTR("app.opendisplay.audio.driver.debug.b"), CFSTR("Second Android"))
    };
    assert(publish(items, 2, getpid() + 1) == kAudioDevicePermissionsError);
    assert(publish(items, 2, getpid()) == noErr && list(ids, 2) == 2);
    const AudioObjectID first = ids[0], second = ids[1];
    for (int i = 0; i < 100 && atomic_load(&listChanges) == 0; ++i) usleep(1000);
    assert(first != second && listChanges == 1);
    assert(publish(items, 2, getpid()) == noErr && list(ids, 2) == 2 && listChanges == 1);
    assert(first == ids[0] && second == ids[1]);
    assert((*driver)->StartIO(driver, first, 1) == noErr);
    assert((*driver)->StartIO(driver, second, 1) == noErr);

    float left[] = {.5f, 0, -.5f, 0};
    float right[] = {0, .25f, 0, -.25f};
    writeMix(first, left, 2);
    writeMix(second, right, 2);
    assert(readPCM(first, getpid() + 1, kAudioDevicePermissionsError) == NULL);
    assertSamples(second, right, 4);
    assertSamples(first, left, 4);
    assertSamples(first, NULL, 0);

    const float half = .5f;
    const AudioObjectPropertyAddress volume = {kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, 0};
    assert((*driver)->SetPropertyData(driver, first + 2, getpid(), &volume, 0, NULL, sizeof(half), &half) == noErr);
    writeMix(first, left, 2);
    const float quieter[] = {.25f, 0, -.25f, 0};
    assertSamples(first, quieter, 4);
    for (int i = 0; i < 10; ++i) writeMix(second, right, 2);
    float backlog[16];
    for (int i = 0; i < 4; ++i) memcpy(backlog + i * 4, right, sizeof(right));
    assertSamples(second, backlog, 16);
    writeMix(second, right, 2);
    usleep(100000);
    assertSamples(second, NULL, 0);

    writeMix(first, left, 2);
    assert(publish(items + 1, 1, getpid()) == noErr && list(ids, 2) == 1 && ids[0] == second);
    assert((*driver)->StopIO(driver, first, 1) == noErr);
    assert(publish(items, 2, getpid()) == noErr && list(ids, 2) == 2);
    AudioObjectID newFirst = ids[0] == second ? ids[1] : ids[0];
    assert(newFirst != first);
    assertSamples(newFirst, NULL, 0);
    writeMix(newFirst, left, 2);
    assertSamples(newFirst, quieter, 4);
    assert((*driver)->StopIO(driver, second, 1) == noErr);
    // The process lease must remove outputs even without a graceful close.
    for (int i = 0; i < 24 && list(ids, 2); ++i) usleep(250000);
    assert(list(ids, 2) == 0);
    CFRelease(items[0]);
    CFRelease(items[1]);
    puts("HAL registration, two isolated PCM routes, volume, freshness, retirement and lease passed");
}
