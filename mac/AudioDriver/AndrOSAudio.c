//
//  AndrOSAudio.c — CoreAudio sunucu eklentisi (AudioServerPlugIn).
//
//  macOS'un ses panelinde iki cihaz aciyor:
//    • "AndrOS Hoparlör"  (cikis) — Mac'in sesi telefona gider
//    • "AndrOS Mikrofon"  (giris) — telefonun mikrofonu Mac'e gelir
//
//  Boylece telefon, Mac'e takili bir kulaklik/mikrofon gibi davraniyor:
//  kulakligi TELEFONA takip Mac'in sesini oradan dinleyebiliyor, ayni
//  anda telefonun mikrofonunu Mac'te kullanabiliyorsun.
//
//  Neden eski DAL/kext degil: macOS 12.3'ten beri kullanicidan
//  yuklenen ses eklentileri icin desteklenen tek yol AudioServerPlugIn.
//  `coreaudiod` bu paketi /Library/Audio/Plug-Ins/HAL altindan yukluyor.
//
//  Veri yolu: bu eklenti GERCEK ZAMANLI ses is parcaciginda calisiyor.
//  Orada kilit almak, bellek ayirmak ya da ag beklemek dogrudan ses
//  kesilmesi demek. Bu yuzden burasi yalnizca paylasimli bellekteki
//  halka tampona yaziyor/okuyor; ag isini AndrOS uygulamasi yapiyor.
//
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdatomic.h>

#include "AndrOSAudioShared.h"

#pragma mark - Nesneler

/* Nesne kimlikleri sabit: eklenti kucuk ve degismez bir agac sunuyor. */
enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,   /* 1 */
    kObjectID_Device_Out    = 2,
    kObjectID_Stream_Out    = 3,
    kObjectID_Device_In     = 4,
    kObjectID_Stream_In     = 5,
};

#define kDeviceUID_Out  "dev.naer.andros.audio.output"
#define kDeviceUID_In   "dev.naer.andros.audio.input"
#define kBoxUID         "dev.naer.andros.audio.box"

/* Ses geri cagrisi bir turda kac kare istiyor (ipucu). */
#define kRingSizeFrames  ANDROS_RING_FRAMES

static AudioServerPlugInDriverRef   gDriver     = NULL;
static AudioServerPlugInHostRef     gHost       = NULL;
static pthread_mutex_t              gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32                       gRefCount   = 0;

/* Paylasimli bellek */
static AndrOSAudioShared*           gShared     = NULL;
static int                          gShmFD      = -1;

/* Cihaz durumu */
static UInt32   gOutIOCount = 0;      /* kac istemci cikis akisini actı */
static UInt32   gInIOCount  = 0;
static Float64  gHostTicksPerFrame = 0.0;
static UInt64   gOutAnchorHostTime = 0;
static UInt64   gOutAnchorSample   = 0;
static UInt64   gInAnchorHostTime  = 0;
static UInt64   gInAnchorSample    = 0;
static Float32  gOutVolume = 1.0f;

#pragma mark - Paylasimli bellek

/*  Halka tamponu ac ya da olustur.
 *
 *  Eklenti `coreaudiod` icinde ROOT olarak calisiyor, uygulama ise
 *  kullanici olarak. Bu yuzden 0666 iznine ihtiyac var; `fchmod` da
 *  cagriliyor cunku `shm_open` maskeyi uygular ve umask kisitlayabilir.
 */
static void EnsureShared(void)
{
    if (gShared != NULL) return;

    int fd = shm_open(ANDROS_SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0) return;
    fchmod(fd, 0666);

    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size < (off_t)sizeof(AndrOSAudioShared)) {
        if (ftruncate(fd, (off_t)sizeof(AndrOSAudioShared)) != 0) {
            close(fd);
            return;
        }
    }
    void* p = mmap(NULL, sizeof(AndrOSAudioShared), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { close(fd); return; }

    gShmFD = fd;
    gShared = (AndrOSAudioShared*)p;
    if (gShared->magic != ANDROS_MAGIC) {
        memset(gShared, 0, sizeof(*gShared));
        gShared->magic = ANDROS_MAGIC;
        gShared->version = ANDROS_VERSION;
    }
}

#pragma mark - Bicim

static void FillFormat(AudioStreamBasicDescription* d)
{
    memset(d, 0, sizeof(*d));
    d->mSampleRate       = ANDROS_RATE;
    d->mFormatID         = kAudioFormatLinearPCM;
    d->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
                         | kAudioFormatFlagIsPacked;
    d->mBytesPerPacket   = 4 * ANDROS_CHANNELS;
    d->mFramesPerPacket  = 1;
    d->mBytesPerFrame    = 4 * ANDROS_CHANNELS;
    d->mChannelsPerFrame = ANDROS_CHANNELS;
    d->mBitsPerChannel   = 32;
}

static bool IsOutputObject(AudioObjectID o)
{
    return o == kObjectID_Device_Out || o == kObjectID_Stream_Out;
}

#pragma mark - Ilklendirme

static OSStatus Ndr_Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host)
{
    if (d != gDriver) return kAudioHardwareBadObjectError;
    gHost = host;

    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    /* Bir karenin kac makine tiki surdugu: zaman damgasi bunun uzerinden. */
    Float64 nanosPerFrame = 1000000000.0 / (Float64)ANDROS_RATE;
    gHostTicksPerFrame = nanosPerFrame * (Float64)tb.denom / (Float64)tb.numer;

    EnsureShared();
    return 0;
}

static OSStatus Ndr_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
                                 const AudioServerPlugInClientInfo* c, AudioObjectID* out)
{ (void)d; (void)desc; (void)c; (void)out; return kAudioHardwareUnsupportedOperationError; }

static OSStatus Ndr_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o)
{ (void)d; (void)o; return kAudioHardwareUnsupportedOperationError; }

static OSStatus Ndr_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o,
                                    const AudioServerPlugInClientInfo* c)
{ (void)d; (void)o; (void)c; return 0; }

static OSStatus Ndr_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o,
                                       const AudioServerPlugInClientInfo* c)
{ (void)d; (void)o; (void)c; return 0; }

static OSStatus Ndr_PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID o,
                                        UInt64 change, void* info)
{ (void)d; (void)o; (void)change; (void)info; return 0; }

static OSStatus Ndr_AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID o,
                                      UInt64 change, void* info)
{ (void)d; (void)o; (void)change; (void)info; return 0; }

#pragma mark - Ozellikler

/*  Ozellik tablosu.
 *
 *  CoreAudio her nesneyi ozellik sorgulariyla kesfediyor; asagisi o
 *  sorgularin karsiligi. Uzun ama duz: her `switch` dali tek bir
 *  ozelligi yanitliyor.
 */

static Boolean Ndr_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t c,
                               const AudioObjectPropertyAddress* a)
{
    (void)d; (void)c;
    switch (obj) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;

    case kObjectID_Device_Out:
    case kObjectID_Device_In:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyIcon:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return true;
        }
        return false;

    case kObjectID_Stream_Out:
    case kObjectID_Stream_In:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus Ndr_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t c,
                                       const AudioObjectPropertyAddress* a, Boolean* settable)
{
    (void)d; (void)c;
    if (settable == NULL) return kAudioHardwareIllegalOperationError;
    *settable = false;
    if (obj == kObjectID_Device_Out || obj == kObjectID_Device_In) {
        /* Ornekleme hizi tek deger; degistirilebilir gorunmesi
           uygulamalarin "ayarlayabildim" saymasi icin yeterli. */
        if (a->mSelector == kAudioDevicePropertyNominalSampleRate) *settable = true;
    }
    if (obj == kObjectID_Stream_Out || obj == kObjectID_Stream_In) {
        if (a->mSelector == kAudioStreamPropertyIsActive) *settable = true;
    }
    return 0;
}

static OSStatus Ndr_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t c,
                                        const AudioObjectPropertyAddress* a,
                                        UInt32 qdSize, const void* qd, UInt32* outSize)
{
    (void)d; (void)c; (void)qdSize; (void)qd;
    if (outSize == NULL) return kAudioHardwareIllegalOperationError;

    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
        *outSize = sizeof(AudioClassID); return 0;
    case kAudioObjectPropertyOwner:
        *outSize = sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
        *outSize = sizeof(CFStringRef); return 0;
    case kAudioObjectPropertyOwnedObjects:
        if (obj == kObjectID_PlugIn) { *outSize = 2 * sizeof(AudioObjectID); return 0; }
        *outSize = sizeof(AudioObjectID); return 0;      /* cihaz -> 1 akis */
    case kAudioPlugInPropertyDeviceList:
        *outSize = 2 * sizeof(AudioObjectID); return 0;
    case kAudioPlugInPropertyTranslateUIDToDevice:
        *outSize = sizeof(AudioObjectID); return 0;
    case kAudioPlugInPropertyResourceBundle:
        *outSize = sizeof(CFStringRef); return 0;
    case kAudioDevicePropertyStreams:
        *outSize = sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyControlList:
        *outSize = 0; return 0;
    case kAudioDevicePropertyRelatedDevices:
        *outSize = sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyIsHidden:
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:
        *outSize = sizeof(UInt32); return 0;
    case kAudioDevicePropertyNominalSampleRate:
        *outSize = sizeof(Float64); return 0;
    case kAudioDevicePropertyAvailableNominalSampleRates:
        *outSize = sizeof(AudioValueRange); return 0;
    case kAudioDevicePropertyIcon:
        *outSize = sizeof(CFURLRef); return 0;
    case kAudioDevicePropertyPreferredChannelsForStereo:
        *outSize = 2 * sizeof(UInt32); return 0;
    case kAudioDevicePropertyPreferredChannelLayout:
        *outSize = offsetof(AudioChannelLayout, mChannelDescriptions)
                 + (2 * sizeof(AudioChannelDescription)); return 0;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        *outSize = sizeof(AudioStreamBasicDescription); return 0;
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
        *outSize = sizeof(AudioStreamRangedDescription); return 0;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Ndr_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t c,
                                    const AudioObjectPropertyAddress* a,
                                    UInt32 qdSize, const void* qd,
                                    UInt32 inSize, UInt32* outSize, void* out)
{
    (void)d; (void)c; (void)qdSize;
    if (outSize == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    const bool isOut = IsOutputObject(obj);

    switch (a->mSelector) {

    case kAudioObjectPropertyBaseClass:
        if (inSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
        *((AudioClassID*)out) =
            (obj == kObjectID_PlugIn) ? kAudioObjectClassID :
            (obj == kObjectID_Device_Out || obj == kObjectID_Device_In) ? kAudioObjectClassID
                                                                       : kAudioObjectClassID;
        *outSize = sizeof(AudioClassID); return 0;

    case kAudioObjectPropertyClass:
        if (inSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
        *((AudioClassID*)out) =
            (obj == kObjectID_PlugIn) ? kAudioPlugInClassID :
            (obj == kObjectID_Device_Out || obj == kObjectID_Device_In) ? kAudioDeviceClassID
                                                                       : kAudioStreamClassID;
        *outSize = sizeof(AudioClassID); return 0;

    case kAudioObjectPropertyOwner: {
        if (inSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
        AudioObjectID owner = kAudioObjectUnknown;
        if (obj == kObjectID_Device_Out || obj == kObjectID_Device_In) owner = kObjectID_PlugIn;
        else if (obj == kObjectID_Stream_Out) owner = kObjectID_Device_Out;
        else if (obj == kObjectID_Stream_In)  owner = kObjectID_Device_In;
        *((AudioObjectID*)out) = owner;
        *outSize = sizeof(AudioObjectID); return 0;
    }

    case kAudioObjectPropertyName: {
        if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        CFStringRef s = NULL;
        switch (obj) {
        case kObjectID_Device_Out: s = CFSTR("AndrOS · Telefon (Hoparlör)"); break;
        case kObjectID_Device_In:  s = CFSTR("AndrOS · Telefon (Mikrofon)"); break;
        case kObjectID_Stream_Out: s = CFSTR("AndrOS Çıkış"); break;
        case kObjectID_Stream_In:  s = CFSTR("AndrOS Giriş"); break;
        default: return kAudioHardwareUnknownPropertyError;
        }
        *((CFStringRef*)out) = CFStringCreateCopy(NULL, s);
        *outSize = sizeof(CFStringRef); return 0;
    }

    case kAudioObjectPropertyManufacturer:
        if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        *((CFStringRef*)out) = CFStringCreateCopy(NULL, CFSTR("AndrOS"));
        *outSize = sizeof(CFStringRef); return 0;

    case kAudioObjectPropertyOwnedObjects: {
        AudioObjectID ids[2];
        UInt32 n = 0;
        if (obj == kObjectID_PlugIn) {
            ids[0] = kObjectID_Device_Out; ids[1] = kObjectID_Device_In; n = 2;
        } else if (obj == kObjectID_Device_Out) { ids[0] = kObjectID_Stream_Out; n = 1; }
        else if (obj == kObjectID_Device_In)    { ids[0] = kObjectID_Stream_In;  n = 1; }
        UInt32 fit = inSize / sizeof(AudioObjectID);
        if (fit > n) fit = n;
        memcpy(out, ids, fit * sizeof(AudioObjectID));
        *outSize = fit * sizeof(AudioObjectID); return 0;
    }

    case kAudioPlugInPropertyDeviceList: {
        AudioObjectID ids[2] = { kObjectID_Device_Out, kObjectID_Device_In };
        UInt32 fit = inSize / sizeof(AudioObjectID);
        if (fit > 2) fit = 2;
        memcpy(out, ids, fit * sizeof(AudioObjectID));
        *outSize = fit * sizeof(AudioObjectID); return 0;
    }

    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (inSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = *((const CFStringRef*)qd);
        AudioObjectID r = kAudioObjectUnknown;
        if (uid && CFStringCompare(uid, CFSTR(kDeviceUID_Out), 0) == kCFCompareEqualTo)
            r = kObjectID_Device_Out;
        else if (uid && CFStringCompare(uid, CFSTR(kDeviceUID_In), 0) == kCFCompareEqualTo)
            r = kObjectID_Device_In;
        *((AudioObjectID*)out) = r;
        *outSize = sizeof(AudioObjectID); return 0;
    }

    case kAudioPlugInPropertyResourceBundle:
        if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        *((CFStringRef*)out) = CFStringCreateCopy(NULL, CFSTR(""));
        *outSize = sizeof(CFStringRef); return 0;

    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
        if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        *((CFStringRef*)out) = CFStringCreateCopy(
            NULL, isOut ? CFSTR(kDeviceUID_Out) : CFSTR(kDeviceUID_In));
        *outSize = sizeof(CFStringRef); return 0;

    case kAudioDevicePropertyTransportType:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        /* "Sanal" tur: ses paneli bunu ayri bir cihaz gibi gosterir. */
        *((UInt32*)out) = kAudioDeviceTransportTypeVirtual;
        *outSize = sizeof(UInt32); return 0;

    case kAudioDevicePropertyRelatedDevices: {
        /* Giris ve cikis AYNI telefonun iki yuzu: birlikte listelensinler. */
        AudioObjectID r = isOut ? kObjectID_Device_Out : kObjectID_Device_In;
        UInt32 fit = inSize / sizeof(AudioObjectID);
        if (fit > 1) fit = 1;
        memcpy(out, &r, fit * sizeof(AudioObjectID));
        *outSize = fit * sizeof(AudioObjectID); return 0;
    }

    case kAudioDevicePropertyClockDomain:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = 0;
        *outSize = sizeof(UInt32); return 0;

    case kAudioDevicePropertyDeviceIsAlive:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        /* Cihazlar HER ZAMAN canli: uygulama kapaliyken kaybolsalardi
           ses paneli titrer ve kullanicinin secimi baska cihaza kacardi. */
        *((UInt32*)out) = 1;
        *outSize = sizeof(UInt32); return 0;

    case kAudioDevicePropertyDeviceIsRunning:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = isOut ? (gOutIOCount > 0) : (gInIOCount > 0);
        *outSize = sizeof(UInt32); return 0;

    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = 1;
        *outSize = sizeof(UInt32); return 0;

    /* kAudioDevicePropertyLatency ile kAudioStreamPropertyLatency ayni
       sayisal degere sahip ('ltnc'); tek dal ikisini de karsiliyor. */
    case kAudioDevicePropertyLatency:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = 0;
        *outSize = sizeof(UInt32); return 0;

    case kAudioDevicePropertySafetyOffset:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = 0;
        *outSize = sizeof(UInt32); return 0;

    case kAudioDevicePropertyStreams: {
        AudioObjectID s = isOut ? kObjectID_Stream_Out : kObjectID_Stream_In;
        UInt32 want = 1;
        /* Kapsam onemli: cikis cihazinin giris akisi yok, tersi de oyle. */
        if (a->mScope == kAudioObjectPropertyScopeInput  && isOut)  want = 0;
        if (a->mScope == kAudioObjectPropertyScopeOutput && !isOut) want = 0;
        UInt32 fit = inSize / sizeof(AudioObjectID);
        if (fit > want) fit = want;
        if (fit) memcpy(out, &s, sizeof(AudioObjectID));
        *outSize = fit * sizeof(AudioObjectID); return 0;
    }

    case kAudioObjectPropertyControlList:
        *outSize = 0; return 0;

    case kAudioDevicePropertyNominalSampleRate:
        if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        *((Float64*)out) = (Float64)ANDROS_RATE;
        *outSize = sizeof(Float64); return 0;

    case kAudioDevicePropertyAvailableNominalSampleRates: {
        if (inSize < sizeof(AudioValueRange)) { *outSize = 0; return 0; }
        AudioValueRange r = { (Float64)ANDROS_RATE, (Float64)ANDROS_RATE };
        memcpy(out, &r, sizeof(r));
        *outSize = sizeof(r); return 0;
    }

    case kAudioDevicePropertyIsHidden:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = 0;
        *outSize = sizeof(UInt32); return 0;

    case kAudioDevicePropertyZeroTimeStampPeriod:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = kRingSizeFrames;
        *outSize = sizeof(UInt32); return 0;

    case kAudioDevicePropertyIcon:
        return kAudioHardwareUnknownPropertyError;

    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (inSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        UInt32 p[2] = { 1, 2 };
        memcpy(out, p, sizeof(p));
        *outSize = sizeof(p); return 0;
    }

    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 need = offsetof(AudioChannelLayout, mChannelDescriptions)
                    + 2 * sizeof(AudioChannelDescription);
        if (inSize < need) return kAudioHardwareBadPropertySizeError;
        AudioChannelLayout* l = (AudioChannelLayout*)out;
        memset(l, 0, need);
        l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        l->mNumberChannelDescriptions = 2;
        l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
        l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
        *outSize = need; return 0;
    }

    case kAudioStreamPropertyIsActive:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = 1;
        *outSize = sizeof(UInt32); return 0;

    case kAudioStreamPropertyDirection:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = isOut ? 0 : 1;      /* 0 = cikis, 1 = giris */
        *outSize = sizeof(UInt32); return 0;

    case kAudioStreamPropertyTerminalType:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = isOut ? kAudioStreamTerminalTypeSpeaker
                                : kAudioStreamTerminalTypeMicrophone;
        *outSize = sizeof(UInt32); return 0;

    case kAudioStreamPropertyStartingChannel:
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)out) = 1;
        *outSize = sizeof(UInt32); return 0;

    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        if (inSize < sizeof(AudioStreamBasicDescription))
            return kAudioHardwareBadPropertySizeError;
        AudioStreamBasicDescription f; FillFormat(&f);
        memcpy(out, &f, sizeof(f));
        *outSize = sizeof(f); return 0;
    }

    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        if (inSize < sizeof(AudioStreamRangedDescription)) { *outSize = 0; return 0; }
        AudioStreamRangedDescription r;
        memset(&r, 0, sizeof(r));
        FillFormat(&r.mFormat);
        r.mSampleRateRange.mMinimum = (Float64)ANDROS_RATE;
        r.mSampleRateRange.mMaximum = (Float64)ANDROS_RATE;
        memcpy(out, &r, sizeof(r));
        *outSize = sizeof(r); return 0;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Ndr_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t c,
                                    const AudioObjectPropertyAddress* a,
                                    UInt32 qdSize, const void* qd,
                                    UInt32 inSize, const void* in)
{
    (void)d; (void)obj; (void)c; (void)qdSize; (void)qd; (void)inSize; (void)in;
    /* Tek bicim, tek hiz: degistirilecek bir sey yok. Yine de HATA
       DONMUYORUZ — bazi uygulamalar ayarlayamayinca cihazi eliyor. */
    switch (a->mSelector) {
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        return 0;
    }
    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - Ses dongusu

static OSStatus Ndr_StartIO(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client)
{
    (void)d; (void)client;
    pthread_mutex_lock(&gStateMutex);
    EnsureShared();
    const UInt64 now = mach_absolute_time();
    if (IsOutputObject(obj)) {
        if (gOutIOCount == 0) {
            gOutAnchorHostTime = now;
            gOutAnchorSample = 0;
            if (gShared) { gShared->outRead = gShared->outWrite = 0; gShared->outRunning = 1; }
        }
        gOutIOCount++;
    } else {
        if (gInIOCount == 0) {
            gInAnchorHostTime = now;
            gInAnchorSample = 0;
            if (gShared) { gShared->inRead = gShared->inWrite = 0; gShared->inRunning = 1; }
        }
        gInIOCount++;
    }
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Ndr_StopIO(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client)
{
    (void)d; (void)client;
    pthread_mutex_lock(&gStateMutex);
    if (IsOutputObject(obj)) {
        if (gOutIOCount > 0) gOutIOCount--;
        if (gOutIOCount == 0 && gShared) gShared->outRunning = 0;
    } else {
        if (gInIOCount > 0) gInIOCount--;
        if (gInIOCount == 0 && gShared) gShared->inRunning = 0;
    }
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

/*  Cihazin saati.
 *
 *  Gercek bir donanim olmadigi icin saati BIZ uretiyoruz: her turda
 *  `kRingSizeFrames` kadar ilerleyen, makine saatine bagli duz bir
 *  sayac. Sistem bunu kullanarak ne zaman kac kare isteyecegini
 *  hesapliyor.
 */
static OSStatus Ndr_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                     UInt32 client, Float64* outSample,
                                     UInt64* outHostTime, UInt64* outSeed)
{
    (void)d; (void)client;
    if (!outSample || !outHostTime || !outSeed) return kAudioHardwareIllegalOperationError;
    const bool isOut = IsOutputObject(obj);

    pthread_mutex_lock(&gStateMutex);
    UInt64* anchorHost = isOut ? &gOutAnchorHostTime : &gInAnchorHostTime;
    UInt64* anchorSmp  = isOut ? &gOutAnchorSample   : &gInAnchorSample;
    if (*anchorHost == 0) { *anchorHost = mach_absolute_time(); *anchorSmp = 0; }

    const UInt64 periodTicks = (UInt64)((Float64)kRingSizeFrames * gHostTicksPerFrame);
    const UInt64 now = mach_absolute_time();
    if (periodTicks > 0) {
        while (now >= *anchorHost + periodTicks) {
            *anchorHost += periodTicks;
            *anchorSmp  += kRingSizeFrames;
        }
    }
    *outSample   = (Float64)(*anchorSmp);
    *outHostTime = *anchorHost;
    *outSeed     = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Ndr_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                      UInt32 client, UInt32 op,
                                      Boolean* outWill, Boolean* outWillInPlace)
{
    (void)d; (void)obj; (void)client;
    bool will = (op == kAudioServerPlugInIOOperationWriteMix)
             || (op == kAudioServerPlugInIOOperationReadInput);
    if (outWill) *outWill = will;
    if (outWillInPlace) *outWillInPlace = true;
    return 0;
}

static OSStatus Ndr_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                     UInt32 client, UInt32 op, UInt32 frames,
                                     const AudioServerPlugInIOCycleInfo* info)
{ (void)d; (void)obj; (void)client; (void)op; (void)frames; (void)info; return 0; }

static OSStatus Ndr_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                   UInt32 client, UInt32 op, UInt32 frames,
                                   const AudioServerPlugInIOCycleInfo* info)
{ (void)d; (void)obj; (void)client; (void)op; (void)frames; (void)info; return 0; }

/*  Asil veri alisverisi.
 *
 *  GERCEK ZAMANLI is parcacigi: kilit yok, ayirma yok, sistem cagrisi
 *  yok. Yalnizca halka tampona kopyalama ve atomik sayac guncellemesi.
 */
static OSStatus Ndr_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                  AudioObjectID stream, UInt32 client, UInt32 op,
                                  UInt32 frames, const AudioServerPlugInIOCycleInfo* info,
                                  void* mainBuffer, void* secondaryBuffer)
{
    (void)d; (void)stream; (void)client; (void)info; (void)secondaryBuffer;
    AndrOSAudioShared* sh = gShared;
    if (sh == NULL || frames == 0) return 0;

    if (op == kAudioServerPlugInIOOperationWriteMix && IsOutputObject(obj)) {
        /* Mac'in cikisi -> halka -> koprii -> telefon */
        const float* src = (const float*)mainBuffer;
        if (src == NULL) return 0;
        uint64_t w = sh->outWrite;
        const uint64_t r = sh->outRead;
        /* Tampon dolduysa EN ESKIYI at: gec kalmis sesi biriktirmek
           gecikmeyi buyutur, birakmak yalnizca kisa bir bosluk yaratir. */
        uint64_t space = (uint64_t)ANDROS_RING_FRAMES - (w - r);
        if (space < frames) {
            sh->outRead = w + frames - ANDROS_RING_FRAMES;
        }
        for (UInt32 i = 0; i < frames; i++) {
            const size_t idx = (size_t)((w + i) % ANDROS_RING_FRAMES) * ANDROS_CHANNELS;
            sh->out[idx + 0] = src[i * ANDROS_CHANNELS + 0];
            sh->out[idx + 1] = src[i * ANDROS_CHANNELS + 1];
        }
        atomic_thread_fence(memory_order_release);
        sh->outWrite = w + frames;
        return 0;
    }

    if (op == kAudioServerPlugInIOOperationReadInput && !IsOutputObject(obj)) {
        /* Telefonun mikrofonu -> halka -> Mac'in girisi */
        float* dst = (float*)mainBuffer;
        if (dst == NULL) return 0;
        const uint64_t w = sh->inWrite;
        uint64_t r = sh->inRead;
        atomic_thread_fence(memory_order_acquire);
        const uint64_t avail = w - r;
        if (avail < frames) {
            /* Veri yetismedi: SESSIZLIK ver. Eski veriyi tekrar calmak
               tiz bir cizilme sesi uretiyor. */
            memset(dst, 0, (size_t)frames * ANDROS_CHANNELS * sizeof(float));
            return 0;
        }
        for (UInt32 i = 0; i < frames; i++) {
            const size_t idx = (size_t)((r + i) % ANDROS_RING_FRAMES) * ANDROS_CHANNELS;
            dst[i * ANDROS_CHANNELS + 0] = sh->in[idx + 0];
            dst[i * ANDROS_CHANNELS + 1] = sh->in[idx + 1];
        }
        sh->inRead = r + frames;
        return 0;
    }
    return 0;
}

#pragma mark - COM iskeleti

static HRESULT Ndr_QueryInterface(void* self, REFIID iid, LPVOID* out)
{
    if (self == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    CFUUIDRef want = CFUUIDCreateFromUUIDBytes(NULL, iid);
    CFUUIDRef me   = CFUUIDGetConstantUUIDWithBytes(NULL,
        0xEE, 0xA5, 0x77, 0x3D, 0xCC, 0x43, 0x49, 0xF1,
        0x8E, 0x00, 0x8F, 0x96, 0xE7, 0xD2, 0x3B, 0x17);  /* AudioServerPlugInDriverInterface */
    CFUUIDRef iun  = CFUUIDGetConstantUUIDWithBytes(NULL,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);  /* IUnknown */
    HRESULT r = E_NOINTERFACE;
    if (want && (CFEqual(want, me) || CFEqual(want, iun))) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *out = gDriver;
        r = S_OK;
    }
    if (want) CFRelease(want);
    return r;
}

static ULONG Ndr_AddRef(void* self)
{
    if (self != (void*)gDriver) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) gRefCount++;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG Ndr_Release(void* self)
{
    if (self != (void*)gDriver) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Ndr_QueryInterface,
    Ndr_AddRef,
    Ndr_Release,
    Ndr_Initialize,
    Ndr_CreateDevice,
    Ndr_DestroyDevice,
    Ndr_AddDeviceClient,
    Ndr_RemoveDeviceClient,
    Ndr_PerformConfigChange,
    Ndr_AbortConfigChange,
    Ndr_HasProperty,
    Ndr_IsPropertySettable,
    Ndr_GetPropertyDataSize,
    Ndr_GetPropertyData,
    Ndr_SetPropertyData,
    Ndr_StartIO,
    Ndr_StopIO,
    Ndr_GetZeroTimeStamp,
    Ndr_WillDoIOOperation,
    Ndr_BeginIOOperation,
    Ndr_DoIOOperation,
    Ndr_EndIOOperation,
};

static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

/*  `coreaudiod` paketi bu isimle yukluyor (bkz. Info.plist). */
void* AndrOSAudioFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void* AndrOSAudioFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;
    if (requestedTypeUUID == NULL) return NULL;
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    gDriver = gDriverRef;
    return gDriverRef;
}
