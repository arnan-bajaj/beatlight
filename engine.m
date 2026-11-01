// engine.m — audio analysis and hardware control for beatlight.
//
// Audio:     system audio via ScreenCaptureKit, or the microphone via AVAudioEngine.
// Analysis:  150 Hz low-pass -> 10 ms RMS frames -> envelope for brightness,
//            onset detection (energy jump over a ~1 s running average) for kicks.
//            Arp mode adds a 1024-point FFT every frame: spectral flux in 250 Hz-4 kHz
//            catches note changes (synth arpeggios) and flickers the keyboard backlight.
//            The trackpad only ever taps on kicks.
// Hardware:  keyboard backlight via private CoreBrightness (KeyboardBrightnessClient),
//            trackpad actuator via private MultitouchSupport (MTActuatorActuate).
//            Both are dlopen'd at runtime, so this builds with the stock Command Line Tools.
//
// Personal use only. Private APIs: a macOS update can break this at any time.

#import "engine.h"
#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <IOKit/IOKitLib.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <dlfcn.h>
#include <math.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>

static const double kSilence = 3e-4;                  // bass RMS below this counts as silence
static const double kRawGate = 1e-3;                  // full-band RMS below this: no arp detection
static const double kFluxFloor = 0.5;                 // ignore spectral-flux peaks smaller than this
static const uint64_t kMinFlickGapNs = 83000000ull;   // backlight flickers: at most ~12/s
static const uint64_t kKickMaskNs = 40000000ull;      // ignore arp onsets within 40 ms of a kick

static NSString *const kScreenPermissionMsg =
    @"no permission to capture system audio. Turn it on in System Settings > Privacy & Security > "
    @"Screen & System Audio Recording, then quit and reopen the app.";
static NSString *const kMicPermissionMsg =
    @"no permission to use the microphone. Turn it on in System Settings > Privacy & Security > Microphone.";

static uint64_t nowNs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

#pragma mark - Shared state

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;   // guards gOpt and gMeter
static BLOptions gOpt;
static BLMeter gMeter;

static atomic_uint gGen;                  // bumped on every start and stop; stale callbacks compare against it
static atomic_bool gKBActive, gHapActive; // hardware actually held (written on gHWQ, read anywhere)
static BOOL gRunning;                     // main thread only

static dispatch_queue_t gHWQ;             // every hardware call is serialized here
static dispatch_queue_t gAudioQ;          // ScreenCaptureKit sample handler queue
static void (^gFailure)(NSString *);

static void ensureQueues(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gHWQ = dispatch_queue_create("beatlight.hw", DISPATCH_QUEUE_SERIAL);
        gAudioQ = dispatch_queue_create("beatlight.audio", DISPATCH_QUEUE_SERIAL);
    });
}

static BLOptions optsGet(void) {
    os_unfair_lock_lock(&gLock);
    BLOptions o = gOpt;
    os_unfair_lock_unlock(&gLock);
    return o;
}

static void optsSet(BLOptions o) {
    os_unfair_lock_lock(&gLock);
    gOpt = o;
    os_unfair_lock_unlock(&gLock);
}

#pragma mark - Options

BLOptions BLDefaultOptions(void) {
    return (BLOptions){ .useMic = NO, .backlight = YES, .haptics = YES, .arp = NO,
                        .minB = 0.05f, .maxB = 1.0f, .sens = 1.6, .hapticRate = 4.0, .hapticID = 4,
                        .arpSens = 1.5, .arpDepth = 0.8f };
}

BLOptions BLClampOptions(BLOptions o) {
    o.minB = fminf(fmaxf(o.minB, 0.0f), 1.0f);
    o.maxB = fminf(fmaxf(o.maxB, 0.0f), 1.0f);
    if (o.minB > o.maxB) { float t = o.minB; o.minB = o.maxB; o.maxB = t; }
    if (!(o.sens > 1.0)) o.sens = 1.05;
    if (!(o.arpSens > 1.0)) o.arpSens = 1.05;
    o.arpDepth = fminf(fmaxf(o.arpDepth, 0.0f), 1.0f);
    if (!(o.hapticRate > 0.0)) { o.haptics = NO; o.hapticRate = 4.0; }
    if (o.hapticRate > BL_HAPTIC_RATE_CAP) o.hapticRate = BL_HAPTIC_RATE_CAP;
    return o;
}

#pragma mark - Keyboard backlight (CoreBrightness, private) — gHWQ only

@protocol KBClient
- (NSArray *)copyKeyboardBacklightIDs;
- (float)brightnessForKeyboard:(unsigned long long)kbID;
- (BOOL)setBrightness:(float)b forKeyboard:(unsigned long long)kbID;
@optional
- (BOOL)setBrightness:(float)b fadeSpeed:(int)speed commit:(BOOL)commit forKeyboard:(unsigned long long)kbID;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(unsigned long long)kbID;
- (BOOL)enableAutoBrightness:(BOOL)enable forKeyboard:(unsigned long long)kbID;
@end

static id<KBClient> gKB;
static unsigned long long gKBID;
static float gKBOriginal;
static BOOL gKBHeld, gKBFast, gKBAutoWas;

// Takes over the backlight: remembers its level and turns off ambient auto-brightness,
// which would fight us. kbRelease() puts both back.
static BOOL kbAcquire(void) {
    if (gKBHeld) return YES;
    if (!gKB) {
        if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)) return NO;
        Class cls = NSClassFromString(@"KeyboardBrightnessClient");
        if (!cls) return NO;
        gKB = (id<KBClient>)[[cls alloc] init];
        if (!gKB) return NO;
    }
    NSArray *ids = [gKB copyKeyboardBacklightIDs];
    if (ids.count == 0) return NO;
    gKBID = [ids.firstObject unsignedLongLongValue];
    gKBOriginal = [gKB brightnessForKeyboard:gKBID];

    id obj = gKB;
    gKBFast = [obj respondsToSelector:@selector(setBrightness:fadeSpeed:commit:forKeyboard:)];
    gKBAutoWas = [obj respondsToSelector:@selector(isAutoBrightnessEnabledForKeyboard:)] &&
                 [obj respondsToSelector:@selector(enableAutoBrightness:forKeyboard:)] &&
                 [gKB isAutoBrightnessEnabledForKeyboard:gKBID];
    if (gKBAutoWas) [gKB enableAutoBrightness:NO forKeyboard:gKBID];

    gKBHeld = YES;
    atomic_store(&gKBActive, true);
    return YES;
}

static void kbRelease(void) {
    if (!gKBHeld) return;
    atomic_store(&gKBActive, false);
    [gKB setBrightness:gKBOriginal forKeyboard:gKBID];
    if (gKBAutoWas) [gKB enableAutoBrightness:YES forKeyboard:gKBID];
    gKBHeld = NO;
}

static void kbSet(float b) {
    if (!gKBHeld) return;
    if (gKBFast) [gKB setBrightness:b fadeSpeed:0 commit:NO forKeyboard:gKBID];
    else         [gKB setBrightness:b forKeyboard:gKBID];
}

#pragma mark - Trackpad haptics (MultitouchSupport, private) — gHWQ only

typedef CFTypeRef (*MTActCreateFn)(UInt64 deviceID);
typedef IOReturn  (*MTActOpenFn)(CFTypeRef act);
typedef IOReturn  (*MTActCloseFn)(CFTypeRef act);
typedef IOReturn  (*MTActActuateFn)(CFTypeRef act, SInt32 actuationID, UInt32 u1, Float32 u2, Float32 u3);

static CFTypeRef gAct;
static MTActCreateFn pCreate;
static MTActOpenFn pOpen;
static MTActCloseFn pClose;
static MTActActuateFn pActuate;

static BOOL hapticOpen(void) {
    if (gAct) return YES;
    if (!pActuate) {
        void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
        if (!h) return NO;
        pCreate  = (MTActCreateFn)dlsym(h, "MTActuatorCreateFromDeviceID");
        pOpen    = (MTActOpenFn)dlsym(h, "MTActuatorOpen");
        pClose   = (MTActCloseFn)dlsym(h, "MTActuatorClose");
        pActuate = (MTActActuateFn)dlsym(h, "MTActuatorActuate");
        if (!pCreate || !pOpen || !pActuate) { pActuate = NULL; return NO; }
    }

    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &it) != KERN_SUCCESS)
        return NO;
    io_object_t svc;
    while (!gAct && (svc = IOIteratorNext(it))) {
        CFTypeRef idRef = IORegistryEntryCreateCFProperty(svc, CFSTR("Multitouch ID"), kCFAllocatorDefault, 0);
        IOObjectRelease(svc);
        if (!idRef) continue;
        UInt64 devID = 0;
        BOOL ok = CFGetTypeID(idRef) == CFNumberGetTypeID() &&
                  CFNumberGetValue((CFNumberRef)idRef, kCFNumberSInt64Type, &devID);
        CFRelease(idRef);
        if (!ok) continue;
        CFTypeRef act = pCreate(devID);
        if (!act) continue;
        if (pOpen(act) == kIOReturnSuccess) gAct = act;
        else CFRelease(act);
    }
    IOObjectRelease(it);
    if (gAct) atomic_store(&gHapActive, true);
    return gAct != NULL;
}

static void hapticClose(void) {
    if (!gAct) return;
    atomic_store(&gHapActive, false);
    if (pClose) pClose(gAct);
    CFRelease(gAct);
    gAct = NULL;
}

static void hapticPulse(int actuationID) {
    if (gAct) pActuate(gAct, actuationID, 0, 0.0f, 2.0f);
}

#pragma mark - Analysis — audio threads only

typedef struct { double b0, b1, b2, a1, a2, z1, z2; } Biquad;

static void biquadLowpass(Biquad *q, double fc, double fs) {
    double w0 = 2.0 * M_PI * fc / fs, c = cos(w0), alpha = sin(w0) / (2.0 * M_SQRT1_2);
    double a0 = 1.0 + alpha;
    q->b0 = (1.0 - c) / 2.0 / a0;
    q->b1 = (1.0 - c) / a0;
    q->b2 = q->b0;
    q->a1 = -2.0 * c / a0;
    q->a2 = (1.0 - alpha) / a0;
    q->z1 = q->z2 = 0.0;
}

static inline double biquadRun(Biquad *q, double x) {   // transposed direct form II
    double y = q->b0 * x + q->z1;
    q->z1 = q->b1 * x - q->a1 * y + q->z2;
    q->z2 = q->b2 * x - q->a2 * y;
    return y;
}

#define kFFTN 1024                       // ~21 ms window at 48 kHz, ~47 Hz per bin

static vDSP_DFT_Setup gDFT;
static float gWin[kFFTN];                // Hann window

static struct {
    unsigned gen;                        // engine run this state belongs to
    double sr, hopSec;
    int hop, n;
    long frames;
    double acc, rawAcc, avg, env, peak;
    double kAvg, kAtk, kRel, peakDecay;
    BOOL armed;
    uint64_t lastPulse, lastOnset, lastArpOnset, lastKB;
    float lastB;
    Biquad lp;
    // arp detection
    float ring[kFFTN];                   // last kFFTN raw samples; ringPos = oldest
    int ringPos;
    float mPrev[kFFTN / 2];              // previous frame's log magnitudes
    int kLo, kHi;                        // FFT bins covering 250 Hz - 4 kHz
    double fluxAvg, flux1, flux2, kFlux;
    // backlight flicker
    double flick, flickDecay;            // flicker envelope: 1 on an arp note, decays in ~50 ms
    uint64_t lastFlick;
} A;

static void analyzerSetup(double sr) {
    if (!gDFT) {
        gDFT = vDSP_DFT_zrop_CreateSetup(NULL, kFFTN, vDSP_DFT_FORWARD);
        for (int i = 0; i < kFFTN; i++) gWin[i] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * i / kFFTN);
    }
    memset(&A, 0, sizeof A);
    A.kLo = (int)fmax(1.0, ceil(250.0 * kFFTN / sr));
    A.kHi = (int)fmin(kFFTN / 2 - 1, floor(4000.0 * kFFTN / sr));
    A.sr = sr;
    A.hop = (int)lround(sr * 0.010);            // 10 ms frames
    A.hopSec = A.hop / sr;
    A.kAvg = 1.0 - exp(-A.hopSec / 1.0);        // ~1 s running average (beat reference)
    A.kAtk = 1.0 - exp(-A.hopSec / 0.010);      // 10 ms attack
    A.kRel = 1.0 - exp(-A.hopSec / 0.180);      // 180 ms release
    A.peakDecay = exp(-A.hopSec / 4.0);         // auto-gain forgets over ~4 s
    A.kFlux = 1.0 - exp(-A.hopSec / 0.5);       // ~0.5 s running average of spectral flux
    A.flickDecay = exp(-A.hopSec / 0.050);      // flicker fades with a 50 ms time constant
    A.peak = kSilence;
    A.armed = YES;
    A.lastB = -1.0f;
    biquadLowpass(&A.lp, 150.0, sr);
}

// Fresh state for each run and whenever the sample rate changes.
static void analyzerPrepare(unsigned gen, double sr) {
    if (A.gen == gen && A.sr == sr) return;
    analyzerSetup(sr);
    A.gen = gen;
}

// Spectral flux over 250 Hz - 4 kHz: how much the spectrum *rose* since the last frame.
// A new synth note moves energy into new bins even at constant loudness, so this catches
// arpeggios that a plain energy detector misses. Log magnitudes make it level-independent.
static double spectralFlux(void) {
    static float inRe[kFFTN / 2], inIm[kFFTN / 2], outRe[kFFTN / 2], outIm[kFFTN / 2];
    for (int i = 0; i < kFFTN / 2; i++) {   // oldest sample first, windowed, even/odd split for zrop
        int a = (A.ringPos + 2 * i) & (kFFTN - 1);
        int b = (A.ringPos + 2 * i + 1) & (kFFTN - 1);
        inRe[i] = A.ring[a] * gWin[2 * i];
        inIm[i] = A.ring[b] * gWin[2 * i + 1];
    }
    vDSP_DFT_Execute(gDFT, inRe, inIm, outRe, outIm);
    double flux = 0.0;
    for (int k = A.kLo; k <= A.kHi; k++) {
        float m = log1pf(hypotf(outRe[k], outIm[k]));
        float d = m - A.mPrev[k];
        if (d > 0.0f) flux += d;
        A.mPrev[k] = m;
    }
    return flux;
}

static void onFrame(double e, double raw) {
    BLOptions o = optsGet();
    uint64_t t = nowNs();
    A.frames++;
    bool kbOn = o.backlight && atomic_load(&gKBActive);
    bool hapOn = o.haptics && atomic_load(&gHapActive);

    // Kick = bass energy jumps well above its recent average. Re-arm once it falls back.
    BOOL onset = NO;
    if (A.armed && e > A.avg * o.sens && e > kSilence) { onset = YES; A.armed = NO; A.lastOnset = t; }
    else if (e < A.avg * 1.1) A.armed = YES;
    A.avg += (e - A.avg) * A.kAvg;

    // Arp note = a local peak in spectral flux well above its recent average.
    // Peak-picking looks one frame back, so it lags by 10 ms.
    BOOL arpOnset = NO;
    if (o.arp && kbOn && gDFT) {
        double f = spectralFlux();
        if (A.frames > 50 &&                                  // let averages settle (~0.5 s)
            A.flux1 > A.flux2 && A.flux1 >= f &&
            A.flux1 > A.fluxAvg * o.arpSens && A.flux1 > kFluxFloor && raw > kRawGate) {
            arpOnset = YES;
            A.lastArpOnset = t;
        }
        A.fluxAvg += (f - A.fluxAvg) * A.kFlux;
        A.flux2 = A.flux1;
        A.flux1 = f;
    }

    // Brightness = bass envelope normalized by a slowly decaying peak (auto-gain).
    A.env += (e - A.env) * (e > A.env ? A.kAtk : A.kRel);
    A.peak = fmax(fmax(A.env, A.peak * A.peakDecay), kSilence);
    double level = fmin(A.env / A.peak, 1.0);
    level *= level;                              // more contrast between hits and gaps

    // Haptics: kicks only, rate-limited.
    if (onset && hapOn) {
        uint64_t minGapNs = (uint64_t)(1e9 / fmin(o.hapticRate, BL_HAPTIC_RATE_CAP));
        if (t - A.lastPulse >= minGapNs) {
            A.lastPulse = t;
            int pattern = o.hapticID;
            dispatch_async(gHWQ, ^{ hapticPulse(pattern); });
        }
    }

    // Backlight flicker: each arp note briefly swings the brightness toward the opposite
    // extreme (a flash when the keyboard is dim, a dip when it's bright), then it fades back.
    // A kick's attack also lights up the mids, so arps within 40 ms of a kick are ignored.
    BOOL flickNow = NO;
    if (arpOnset && t - A.lastOnset > kKickMaskNs && t - A.lastFlick >= kMinFlickGapNs) {
        A.flick = 1.0;
        A.lastFlick = t;
        flickNow = YES;
    }
    double shown = level;
    if (A.flick > 0.02) {
        double target = level > 0.5 ? 0.0 : 1.0;
        shown = level + (target - level) * A.flick * o.arpDepth;
    }
    A.flick *= A.flickDecay;

    // <= ~30 updates/s, plus an immediate update on each flicker so it isn't delayed.
    if (kbOn && (flickNow || t - A.lastKB >= 33000000ull)) {
        float b = o.minB + (o.maxB - o.minB) * (float)shown;
        if (fabsf(b - A.lastB) >= 0.01f) {
            A.lastB = b;
            A.lastKB = t;
            dispatch_async(gHWQ, ^{ kbSet(b); });
        }
    }

    os_unfair_lock_lock(&gLock);
    gMeter.level = shown;
    gMeter.beat = A.lastOnset && t - A.lastOnset < 150000000ull;
    gMeter.arp = A.lastArpOnset && t - A.lastArpOnset < 100000000ull;
    os_unfair_lock_unlock(&gLock);
}

static inline void feedSample(double x) {
    A.ring[A.ringPos] = (float)x;
    A.ringPos = (A.ringPos + 1) & (kFFTN - 1);
    A.rawAcc += x * x;
    double y = biquadRun(&A.lp, x);
    A.acc += y * y;
    if (++A.n >= A.hop) {
        onFrame(sqrt(A.acc / A.n), sqrt(A.rawAcc / A.n));
        A.acc = 0.0;
        A.rawAcc = 0.0;
        A.n = 0;
    }
}

#pragma mark - Failure (main thread)

static void engineFailed(unsigned gen, NSString *reason) {
    if (!gRunning || gen != atomic_load(&gGen)) return;   // already stopped or restarted
    BLStop();
    if (gFailure) gFailure(reason);
}

#pragma mark - System audio (ScreenCaptureKit)

static void handleAudioSampleBuffer(CMSampleBufferRef sb, unsigned gen) {
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    const AudioStreamBasicDescription *asbd = fd ? CMAudioFormatDescriptionGetStreamBasicDescription(fd) : NULL;
    if (!asbd || !(asbd->mFormatFlags & kAudioFormatFlagIsFloat) || asbd->mBitsPerChannel != 32) return;
    analyzerPrepare(gen, asbd->mSampleRate);

    const uint32_t flags = kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment;
    size_t size = 0;
    if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, &size, NULL, 0, NULL, NULL, flags, NULL) != noErr || size == 0)
        return;
    AudioBufferList *abl = malloc(size);
    CMBlockBufferRef block = NULL;
    if (abl && CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, NULL, abl, size, NULL, NULL, flags, &block) == noErr) {
        UInt32 nb = abl->mNumberBuffers;
        if (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
            UInt32 frames = UINT32_MAX;
            for (UInt32 c = 0; c < nb; c++) {
                UInt32 f = abl->mBuffers[c].mDataByteSize / (UInt32)sizeof(float);
                if (f < frames) frames = f;
            }
            if (nb == 0) frames = 0;
            for (UInt32 i = 0; i < frames; i++) {
                double s = 0.0;
                for (UInt32 c = 0; c < nb; c++) s += ((const float *)abl->mBuffers[c].mData)[i];
                feedSample(s / nb);
            }
        } else if (nb > 0) {
            UInt32 ch = asbd->mChannelsPerFrame ? asbd->mChannelsPerFrame : 1;
            const float *p = (const float *)abl->mBuffers[0].mData;
            UInt32 frames = abl->mBuffers[0].mDataByteSize / ((UInt32)sizeof(float) * ch);
            for (UInt32 i = 0; i < frames; i++) {
                double s = 0.0;
                for (UInt32 c = 0; c < ch; c++) s += p[i * ch + c];
                feedSample(s / ch);
            }
        }
    }
    if (block) CFRelease(block);
    free(abl);
}

@interface BLTap : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic) unsigned gen;
@end

@implementation BLTap
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    // Video frames are required by ScreenCaptureKit but ignored.
    if (type == SCStreamOutputTypeAudio && self.gen == atomic_load(&gGen)) handleAudioSampleBuffer(sb, self.gen);
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    unsigned gen = self.gen;
    NSString *reason = error.localizedDescription ?: @"Audio capture stopped.";
    dispatch_async(dispatch_get_main_queue(), ^{ engineFailed(gen, reason); });
}
@end

static SCStream *gStream;
static BLTap *gTap;

static BOOL isUserDeclined(NSError *err) {
    return [err.domain isEqualToString:SCStreamErrorDomain] && err.code == SCStreamErrorUserDeclined;
}

static void startSystemAudio(unsigned gen, BLStartCompletion finish) {
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();   // shows the system prompt the first time
        finish(BLErrorScreenPermission, kScreenPermissionMsg);
        return;
    }
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != atomic_load(&gGen)) { finish(BLErrorCancelled, @"Stopped."); return; }
            if (err) {
                if (isUserDeclined(err)) finish(BLErrorScreenPermission, kScreenPermissionMsg);
                else finish(BLErrorOther, err.localizedDescription);
                return;
            }
            if (content.displays.count == 0) { finish(BLErrorOther, @"No display found to capture audio from."); return; }

            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject excludingWindows:@[]];
            SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
            cfg.capturesAudio = YES;
            cfg.excludesCurrentProcessAudio = YES;
            cfg.sampleRate = 48000;
            cfg.channelCount = 2;
            cfg.width = 2;                                   // video is required but unused: keep it tiny
            cfg.height = 2;
            cfg.minimumFrameInterval = CMTimeMake(1, 1);
            cfg.showsCursor = NO;

            BLTap *tap = [[BLTap alloc] init];
            tap.gen = gen;
            SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:tap];
            NSError *e = nil;
            if (![stream addStreamOutput:tap type:SCStreamOutputTypeAudio sampleHandlerQueue:gAudioQ error:&e] ||
                ![stream addStreamOutput:tap type:SCStreamOutputTypeScreen sampleHandlerQueue:gAudioQ error:&e]) {
                finish(BLErrorOther, e.localizedDescription ?: @"Couldn't set up audio capture.");
                return;
            }
            gStream = stream;
            gTap = tap;
            [stream startCaptureWithCompletionHandler:^(NSError *startErr) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (gen != atomic_load(&gGen)) {
                        [stream stopCaptureWithCompletionHandler:^(NSError *ignored) { (void)tap; }];
                        finish(BLErrorCancelled, @"Stopped.");
                        return;
                    }
                    if (startErr) {
                        if (isUserDeclined(startErr)) finish(BLErrorScreenPermission, kScreenPermissionMsg);
                        else finish(BLErrorOther, startErr.localizedDescription);
                        return;
                    }
                    finish(BLErrorNone, nil);
                });
            }];
        });
    }];
}

#pragma mark - Microphone (AVAudioEngine)

static AVAudioEngine *gEngine;
static id gMicObserver;

static void startMic(unsigned gen, BLStartCompletion finish) {
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    if (fmt.sampleRate <= 0 || fmt.channelCount == 0) {
        finish(BLErrorOther, @"No microphone input available.");
        return;
    }
    [input installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        if (gen != atomic_load(&gGen)) return;
        float *const *data = buf.floatChannelData;
        AVAudioChannelCount nch = buf.format.channelCount;
        if (!data || nch == 0) return;
        analyzerPrepare(gen, buf.format.sampleRate);
        for (AVAudioFrameCount i = 0; i < buf.frameLength; i++) {
            double s = 0.0;
            for (AVAudioChannelCount c = 0; c < nch; c++) s += data[c][i];
            feedSample(s / nch);
        }
    }];
    gEngine = engine;   // set first, so BLStop() can tear it down if starting fails
    NSError *err = nil;
    if (![engine startAndReturnError:&err]) {
        finish(BLErrorOther, err.localizedDescription ?: @"Couldn't start the microphone.");
        return;
    }
    // Switching input devices stops the engine; report it instead of going silent.
    gMicObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:AVAudioEngineConfigurationChangeNotification object:engine
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { engineFailed(gen, @"The audio input device changed."); }];
    finish(BLErrorNone, nil);
}

static void startMicWithPermission(unsigned gen, BLStartCompletion finish) {
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
        case AVAuthorizationStatusAuthorized:
            startMic(gen, finish);
            break;
        case AVAuthorizationStatusNotDetermined:
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (gen != atomic_load(&gGen)) { finish(BLErrorCancelled, @"Stopped."); return; }
                    if (granted) startMic(gen, finish);
                    else finish(BLErrorMicPermission, kMicPermissionMsg);
                });
            }];
            break;
        default:
            finish(BLErrorMicPermission, kMicPermissionMsg);
            break;
    }
}

#pragma mark - Public API

void BLStart(BLOptions opts, BLStartCompletion completion) {
    ensureQueues();
    if (gRunning) { completion(BLErrorNone, nil); return; }
    opts = BLClampOptions(opts);
    optsSet(opts);
    unsigned gen = atomic_fetch_add(&gGen, 1) + 1;
    gRunning = YES;

    __block BOOL any = NO;
    dispatch_sync(gHWQ, ^{
        if (opts.backlight && kbAcquire()) any = YES;
        if (opts.haptics && hapticOpen()) any = YES;
    });
    if (!any) {
        BLStop();
        completion(BLErrorNoOutputs,
                   @"nothing to drive: the keyboard backlight and trackpad are turned off or not reachable on this Mac.");
        return;
    }

    BLStartCompletion finish = ^(BLError code, NSString *message) {
        if (gen != atomic_load(&gGen)) { completion(BLErrorCancelled, @"Stopped."); return; }   // superseded
        if (code != BLErrorNone) BLStop();
        completion(code, message);
    };
    if (opts.useMic) startMicWithPermission(gen, finish);
    else startSystemAudio(gen, finish);
}

void BLStop(void) {
    if (!gRunning) return;
    gRunning = NO;
    atomic_fetch_add(&gGen, 1);   // stale audio callbacks now ignore themselves

    if (gMicObserver) { [NSNotificationCenter.defaultCenter removeObserver:gMicObserver]; gMicObserver = nil; }
    if (gEngine) {
        [gEngine.inputNode removeTapOnBus:0];
        [gEngine stop];
        gEngine = nil;
    }
    if (gStream) {
        SCStream *stream = gStream;
        BLTap *tap = gTap;
        gStream = nil;
        gTap = nil;
        // Keep the stream and its output object alive until the stop completes.
        [stream stopCaptureWithCompletionHandler:^(NSError *ignored) { (void)stream; (void)tap; }];
    }
    dispatch_sync(gHWQ, ^{
        kbRelease();
        hapticClose();
    });
    os_unfair_lock_lock(&gLock);
    gMeter = (BLMeter){ 0 };
    os_unfair_lock_unlock(&gLock);
}

BOOL BLIsRunning(void) { return gRunning; }

void BLUpdateOptions(BLOptions o) {
    ensureQueues();
    o = BLClampOptions(o);
    BLOptions old = optsGet();
    o.useMic = old.useMic;   // a source change needs a restart
    optsSet(o);
    if (!gRunning) return;
    dispatch_sync(gHWQ, ^{
        if (o.backlight && !old.backlight) kbAcquire();
        else if (!o.backlight && old.backlight) kbRelease();
        if (o.haptics && !old.haptics) hapticOpen();
        else if (!o.haptics && old.haptics) hapticClose();
    });
}

void BLSetFailureHandler(void (^handler)(NSString *reason)) { gFailure = handler; }

BOOL BLBacklightActive(void) { return atomic_load(&gKBActive); }
BOOL BLHapticsActive(void) { return atomic_load(&gHapActive); }

BLMeter BLCurrentMeter(void) {
    os_unfair_lock_lock(&gLock);
    BLMeter m = gMeter;
    os_unfair_lock_unlock(&gLock);
    return m;
}
