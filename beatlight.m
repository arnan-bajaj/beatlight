// beatlight — pulse a MacBook's keyboard backlight and trackpad haptics to music.
//
// Audio:     system audio via ScreenCaptureKit (default) or the microphone (--mic).
// Analysis:  150 Hz low-pass -> 10 ms RMS frames -> envelope for brightness,
//            onset detection (energy jump over a ~1 s running average) for beats.
//            --arp adds a 1024-point FFT every frame: spectral flux in 250 Hz-4 kHz
//            catches note changes (synth arpeggios) and flickers the keyboard backlight.
//            The trackpad only ever taps on kicks.
// Hardware:  keyboard backlight via private CoreBrightness (KeyboardBrightnessClient),
//            trackpad actuator via private MultitouchSupport (MTActuatorActuate).
//            Both are dlopen'd at runtime, so this builds with the stock Command Line Tools.
//
// Personal use only. Private APIs: a macOS update can break this at any time.
// Build: ./build.sh     Run: ./beatlight --help

#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <IOKit/IOKitLib.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <dlfcn.h>
#include <math.h>
#include <signal.h>
#include <string.h>
#include <time.h>

#pragma mark - Options

static struct {
    BOOL useMic, backlight, haptics, verbose, arp;
    float minB, maxB;    // backlight range, 0..1
    double sens;         // beat threshold: multiple of the running bass average
    double hapticRate;   // max haptic pulses per second
    int hapticID;        // MTActuatorActuate actuation ID (3 weak, 4 medium, 6 strong)
    double arpSens;      // arp threshold: multiple of the running spectral-flux average
    float arpDepth;      // how far a backlight flicker swings toward the opposite brightness, 0..1
} opt = { .backlight = YES, .haptics = YES, .minB = 0.05f, .maxB = 1.0f, .sens = 1.6,
          .hapticRate = 4.0, .hapticID = 4, .arpSens = 1.5, .arpDepth = 0.8f };

static const double kHapticRateCap = 8.0;   // hard ceiling, regardless of flags

static const double kSilence = 3e-4;        // bass RMS below this counts as silence
static const double kRawGate = 1e-3;        // full-band RMS below this: no arp detection
static const double kFluxFloor = 0.5;       // ignore spectral-flux peaks smaller than this
static const uint64_t kMinFlickGapNs = 83000000ull;   // backlight flickers: at most ~12/s
static const uint64_t kKickMaskNs = 40000000ull;      // ignore arp onsets within 40 ms of a kick

static uint64_t nowNs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static dispatch_queue_t gHWQ;               // all hardware calls are serialized here
static volatile BOOL gStopping = NO;

#pragma mark - Keyboard backlight (CoreBrightness, private)

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
static BOOL gKBReady, gKBFast, gKBAutoKnown, gKBAutoWas;

static BOOL kbInit(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)) return NO;
    Class cls = NSClassFromString(@"KeyboardBrightnessClient");
    if (!cls) return NO;
    gKB = (id<KBClient>)[[cls alloc] init];
    NSArray *ids = [gKB copyKeyboardBacklightIDs];
    if (ids.count == 0) return NO;
    gKBID = [ids.firstObject unsignedLongLongValue];
    gKBOriginal = [gKB brightnessForKeyboard:gKBID];

    id obj = gKB;
    gKBFast = [obj respondsToSelector:@selector(setBrightness:fadeSpeed:commit:forKeyboard:)];
    // Ambient-light auto brightness would fight us; turn it off and restore on exit.
    if ([obj respondsToSelector:@selector(isAutoBrightnessEnabledForKeyboard:)] &&
        [obj respondsToSelector:@selector(enableAutoBrightness:forKeyboard:)]) {
        gKBAutoKnown = YES;
        gKBAutoWas = [gKB isAutoBrightnessEnabledForKeyboard:gKBID];
        if (gKBAutoWas) [gKB enableAutoBrightness:NO forKeyboard:gKBID];
    }
    return YES;
}

static void kbSet(float b) {
    if (gKBFast) [gKB setBrightness:b fadeSpeed:0 commit:NO forKeyboard:gKBID];
    else         [gKB setBrightness:b forKeyboard:gKBID];
}

static void kbRestore(void) {
    [gKB setBrightness:gKBOriginal forKeyboard:gKBID];
    if (gKBAutoKnown && gKBAutoWas) [gKB enableAutoBrightness:YES forKeyboard:gKBID];
}

#pragma mark - Trackpad haptics (MultitouchSupport, private)

typedef CFTypeRef (*MTActCreateFn)(UInt64 deviceID);
typedef IOReturn  (*MTActOpenFn)(CFTypeRef act);
typedef IOReturn  (*MTActCloseFn)(CFTypeRef act);
typedef IOReturn  (*MTActActuateFn)(CFTypeRef act, SInt32 actuationID, UInt32 u1, Float32 u2, Float32 u3);

static CFTypeRef gAct;
static MTActCloseFn pClose;
static MTActActuateFn pActuate;

static BOOL hapticInit(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!h) return NO;
    MTActCreateFn pCreate = (MTActCreateFn)dlsym(h, "MTActuatorCreateFromDeviceID");
    MTActOpenFn   pOpen   = (MTActOpenFn)dlsym(h, "MTActuatorOpen");
    pClose   = (MTActCloseFn)dlsym(h, "MTActuatorClose");
    pActuate = (MTActActuateFn)dlsym(h, "MTActuatorActuate");
    if (!pCreate || !pOpen || !pActuate) return NO;

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
    return gAct != NULL;
}

static void hapticPulse(void) {
    pActuate(gAct, opt.hapticID, 0, 0.0f, 2.0f);
}

#pragma mark - Shutdown (always restores the backlight)

static SCStream *gStream;
static AVAudioEngine *gEngine;

__attribute__((noreturn)) static void shutdownAndExit(int code) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gStopping = YES;
        if (gEngine) [gEngine stop];
        if (gStream) [gStream stopCaptureWithCompletionHandler:nil];
        dispatch_sync(gHWQ, ^{
            if (gKBReady) kbRestore();
            if (gAct) { if (pClose) pClose(gAct); CFRelease(gAct); gAct = NULL; }
        });
        fprintf(stderr, "%sbeatlight: keyboard backlight restored.\n", opt.verbose ? "\n" : "");
    });
    exit(code);
}

#pragma mark - Analysis

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
    double sr, hopSec;
    int hop, n;
    long frames;
    double acc, rawAcc, avg, env, peak;
    double kAvg, kAtk, kRel, peakDecay;
    BOOL armed;
    uint64_t lastPulse, lastOnset, lastArpOnset, lastKB, lastMeter;
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
    uint64_t t = nowNs();
    A.frames++;

    // Beat = bass energy jumps well above its recent average. Re-arm once it falls back.
    BOOL onset = NO;
    if (A.armed && e > A.avg * opt.sens && e > kSilence) { onset = YES; A.armed = NO; A.lastOnset = t; }
    else if (e < A.avg * 1.1) A.armed = YES;
    A.avg += (e - A.avg) * A.kAvg;

    // Arp note = a local peak in spectral flux well above its recent average.
    // Peak-picking looks one frame back, so it lags by 10 ms.
    BOOL arpOnset = NO;
    if (opt.arp && gKBReady && opt.backlight && gDFT) {
        double f = spectralFlux();
        if (A.frames > 50 &&                                  // let averages settle (~0.5 s)
            A.flux1 > A.flux2 && A.flux1 >= f &&
            A.flux1 > A.fluxAvg * opt.arpSens && A.flux1 > kFluxFloor && raw > kRawGate) {
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
    if (onset && gAct && opt.haptics) {
        uint64_t minGapNs = (uint64_t)(1e9 / fmin(opt.hapticRate, kHapticRateCap));
        if (t - A.lastPulse >= minGapNs) {
            A.lastPulse = t;
            dispatch_async(gHWQ, ^{ if (!gStopping) hapticPulse(); });
        }
    }

    // Backlight flicker: each arp note briefly swings the brightness toward the opposite
    // extreme (a flash when the keyboard is dim, a dip when it's bright), then it fades back.
    // A kick's attack also lights up the mids, so arps within 40 ms of a kick are ignored.
    BOOL flickNow = NO;
    if (arpOnset && t - A.lastOnset > kKickMaskNs &&
        t - A.lastFlick >= kMinFlickGapNs) {
        A.flick = 1.0;
        A.lastFlick = t;
        flickNow = YES;
    }
    double shown = level;
    if (A.flick > 0.02) {
        double target = level > 0.5 ? 0.0 : 1.0;
        shown = level + (target - level) * A.flick * opt.arpDepth;
    }
    A.flick *= A.flickDecay;

    // <= ~30 updates/s, plus an immediate update on each flicker so it isn't delayed.
    if (gKBReady && opt.backlight && (flickNow || t - A.lastKB >= 33000000ull)) {
        float b = opt.minB + (opt.maxB - opt.minB) * (float)shown;
        if (fabsf(b - A.lastB) >= 0.01f) {
            A.lastB = b;
            A.lastKB = t;
            dispatch_async(gHWQ, ^{ if (!gStopping) kbSet(b); });
        }
    }

    if (opt.verbose && t - A.lastMeter >= 80000000ull) {
        A.lastMeter = t;
        int bars = (int)lround(shown * 30.0);
        if (bars < 0) bars = 0;
        if (bars > 30) bars = 30;
        char meter[31];
        memset(meter, '#', (size_t)bars);
        memset(meter + bars, ' ', (size_t)(30 - bars));
        meter[30] = '\0';
        fprintf(stderr, "\r[%s] %s %s", meter,
                (t - A.lastOnset < 150000000ull) ? "BEAT" : "    ",
                (opt.arp && t - A.lastArpOnset < 100000000ull) ? "ARP" : "   ");
    }
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

#pragma mark - System audio (ScreenCaptureKit)

static void handleAudioSampleBuffer(CMSampleBufferRef sb) {
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    const AudioStreamBasicDescription *asbd = fd ? CMAudioFormatDescriptionGetStreamBasicDescription(fd) : NULL;
    if (!asbd || !(asbd->mFormatFlags & kAudioFormatFlagIsFloat) || asbd->mBitsPerChannel != 32) return;
    if (A.sr != asbd->mSampleRate) analyzerSetup(asbd->mSampleRate);

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
@end

@implementation BLTap
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (type == SCStreamOutputTypeAudio) handleAudioSampleBuffer(sb);   // video frames are ignored
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    fprintf(stderr, "\nbeatlight: capture stopped: %s\n", error.localizedDescription.UTF8String);
    shutdownAndExit(1);
}
@end

static BLTap *gTap;
static dispatch_queue_t gAudioQ;

static void permissionHelp(void) {
    fprintf(stderr,
        "beatlight: no permission to capture system audio.\n"
        "  System Settings > Privacy & Security > Screen & System Audio Recording:\n"
        "  enable your terminal app (Terminal, iTerm, ...), quit and reopen it, then run again.\n"
        "  Or run with --mic to listen through the microphone instead.\n");
}

static void startSystemAudio(void) {
    if (!CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();   // shows the prompt once
    gTap = [[BLTap alloc] init];
    gAudioQ = dispatch_queue_create("beatlight.audio", DISPATCH_QUEUE_SERIAL);

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *err) {
        if (err || content.displays.count == 0) { permissionHelp(); shutdownAndExit(1); }

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

        gStream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:gTap];
        NSError *e = nil;
        if (![gStream addStreamOutput:gTap type:SCStreamOutputTypeAudio sampleHandlerQueue:gAudioQ error:&e] ||
            ![gStream addStreamOutput:gTap type:SCStreamOutputTypeScreen sampleHandlerQueue:gAudioQ error:&e]) {
            fprintf(stderr, "beatlight: %s\n", e.localizedDescription.UTF8String);
            shutdownAndExit(1);
        }
        [gStream startCaptureWithCompletionHandler:^(NSError *startErr) {
            if (startErr) { permissionHelp(); shutdownAndExit(1); }
            fprintf(stderr, "beatlight: listening to system audio. Ctrl-C to stop.\n");
        }];
    }];
}

#pragma mark - Microphone (AVAudioEngine)

static void startMic(void) {
    gEngine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = gEngine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    if (fmt.sampleRate <= 0 || fmt.channelCount == 0) {
        fprintf(stderr, "beatlight: no microphone input available.\n");
        shutdownAndExit(1);
    }
    analyzerSetup(fmt.sampleRate);
    [input installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        float *const *data = buf.floatChannelData;
        AVAudioChannelCount nch = buf.format.channelCount;
        if (!data || nch == 0) return;
        for (AVAudioFrameCount i = 0; i < buf.frameLength; i++) {
            double s = 0.0;
            for (AVAudioChannelCount c = 0; c < nch; c++) s += data[c][i];
            feedSample(s / nch);
        }
    }];
    NSError *err = nil;
    if (![gEngine startAndReturnError:&err]) {
        fprintf(stderr, "beatlight: mic failed: %s\n", err.localizedDescription.UTF8String);
        shutdownAndExit(1);
    }
    fprintf(stderr, "beatlight: listening on the microphone. Ctrl-C to stop.\n");
}

#pragma mark - CLI

static void usage(void) {
    printf(
        "usage: beatlight [options]\n"
        "  --mic              listen through the microphone instead of system audio\n"
        "  --no-backlight     don't touch the keyboard backlight\n"
        "  --no-haptics       don't use the trackpad actuator\n"
        "  --min X            backlight floor, 0-1 (default 0.05)\n"
        "  --max X            backlight ceiling, 0-1 (default 1.0)\n"
        "  --sens X           beat threshold vs. running average, >1 (default 1.6; lower = more beats)\n"
        "  --haptic-rate N    max haptic pulses per second (default 4, hard cap 8)\n"
        "  --haptic-id N      actuation pattern: 3 weak, 4 medium, 6 strong (default 4)\n"
        "  --arp              flicker the keyboard backlight on synth/arpeggio notes (250 Hz-4 kHz)\n"
        "  --arp-sens X       arp threshold vs. running average, >1 (default 1.5; lower = more flickers)\n"
        "  --arp-depth X      backlight flicker strength, 0-1 (default 0.8)\n"
        "  -v, --verbose      show a live level meter\n");
}

static double argNum(int argc, const char *argv[], int *i) {
    if (*i + 1 >= argc) { fprintf(stderr, "beatlight: %s needs a value\n", argv[*i]); exit(2); }
    char *end = NULL;
    const char *s = argv[++*i];
    double v = strtod(s, &end);
    if (end == s || *end != '\0') { fprintf(stderr, "beatlight: bad number '%s'\n", s); exit(2); }
    return v;
}

static void parseArgs(int argc, const char *argv[]) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if      (!strcmp(a, "--mic"))           opt.useMic = YES;
        else if (!strcmp(a, "--no-backlight"))  opt.backlight = NO;
        else if (!strcmp(a, "--no-haptics"))    opt.haptics = NO;
        else if (!strcmp(a, "--min"))           opt.minB = (float)argNum(argc, argv, &i);
        else if (!strcmp(a, "--max"))           opt.maxB = (float)argNum(argc, argv, &i);
        else if (!strcmp(a, "--sens"))          opt.sens = argNum(argc, argv, &i);
        else if (!strcmp(a, "--haptic-rate"))   opt.hapticRate = argNum(argc, argv, &i);
        else if (!strcmp(a, "--haptic-id"))     opt.hapticID = (int)argNum(argc, argv, &i);
        else if (!strcmp(a, "--arp"))           opt.arp = YES;
        else if (!strcmp(a, "--arp-sens"))      opt.arpSens = argNum(argc, argv, &i);
        else if (!strcmp(a, "--arp-depth"))     opt.arpDepth = (float)argNum(argc, argv, &i);
        else if (!strcmp(a, "-v") || !strcmp(a, "--verbose")) opt.verbose = YES;
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); exit(0); }
        else { fprintf(stderr, "beatlight: unknown option %s\n", a); usage(); exit(2); }
    }
    opt.minB = fminf(fmaxf(opt.minB, 0.0f), 1.0f);
    opt.maxB = fminf(fmaxf(opt.maxB, 0.0f), 1.0f);
    if (opt.minB > opt.maxB) { float t = opt.minB; opt.minB = opt.maxB; opt.maxB = t; }
    if (opt.sens <= 1.0) opt.sens = 1.05;
    if (opt.arpSens <= 1.0) opt.arpSens = 1.05;
    opt.arpDepth = fminf(fmaxf(opt.arpDepth, 0.0f), 1.0f);
    if (opt.arp && !opt.backlight) fprintf(stderr, "beatlight: --arp needs the backlight; ignoring it.\n");
    if (opt.hapticRate <= 0.0) opt.haptics = NO;
    if (opt.hapticRate > kHapticRateCap) {
        fprintf(stderr, "beatlight: haptic rate capped at %.0f/s\n", kHapticRateCap);
        opt.hapticRate = kHapticRateCap;
    }
}

static dispatch_source_t gSignals[2];

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        parseArgs(argc, argv);
        gHWQ = dispatch_queue_create("beatlight.hw", DISPATCH_QUEUE_SERIAL);

        if (opt.backlight && !(gKBReady = kbInit()))
            fprintf(stderr, "beatlight: keyboard backlight not reachable on this Mac; continuing without it.\n");
        if (opt.haptics && !hapticInit())
            fprintf(stderr, "beatlight: trackpad actuator not reachable; continuing without haptics.\n");
        if (!gKBReady && !gAct) { fprintf(stderr, "beatlight: nothing to drive, exiting.\n"); return 1; }

        int sigs[2] = { SIGINT, SIGTERM };
        for (int k = 0; k < 2; k++) {
            signal(sigs[k], SIG_IGN);
            gSignals[k] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sigs[k], 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(gSignals[k], ^{ shutdownAndExit(0); });
            dispatch_resume(gSignals[k]);
        }

        if (opt.useMic) startMic(); else startSystemAudio();
        dispatch_main();
    }
}
