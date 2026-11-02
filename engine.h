// engine.h — beatlight's audio analysis and hardware control, shared by the
// command-line tool (beatlight.m) and the menu bar app (app.m).
//
// Threading: call every function from the main thread. Completions and the
// failure handler are delivered on the main queue.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define BL_HAPTIC_RATE_CAP 8.0   // hard ceiling on trackpad taps per second, regardless of options

typedef struct {
    BOOL useMic;        // listen through the microphone instead of system audio
    BOOL backlight;     // drive the keyboard backlight
    BOOL haptics;       // tap the trackpad on kicks
    BOOL arp;           // flicker the backlight on synth/arpeggio notes (needs backlight)
    float minB, maxB;   // backlight range, 0..1
    double sens;        // beat threshold: multiple of the running bass average, > 1
    double hapticRate;  // max trackpad taps per second (capped at BL_HAPTIC_RATE_CAP)
    int hapticID;       // actuation pattern: 3 weak, 4 medium, 6 strong
    double arpSens;     // arp threshold: multiple of the running spectral-flux average, > 1
    float arpDepth;     // backlight flicker strength, 0..1
    BOOL rgb;           // also pulse RGB devices through OpenRGB's SDK server (orgb.c)
    uint32_t rgbColor;  // 0xRRGGBB pulse color
    BOOL rgbCycle;      // ignore rgbColor; step through the hues, one step per kick
} BLOptions;

typedef NS_ENUM(NSInteger, BLError) {
    BLErrorNone = 0,
    BLErrorScreenPermission,   // no Screen & System Audio Recording permission
    BLErrorMicPermission,      // no microphone permission
    BLErrorNoOutputs,          // no backlight, trackpad or RGB output is turned on and reachable
    BLErrorCancelled,          // BLStop() was called before the start finished
    BLErrorOther,
};

typedef void (^BLStartCompletion)(BLError code, NSString *_Nullable message);

typedef struct {
    double level;   // what the backlight is showing, 0..1
    BOOL beat;      // a kick was detected in the last 150 ms
    BOOL arp;       // an arp note was detected in the last 100 ms
} BLMeter;

BLOptions BLDefaultOptions(void);
BLOptions BLClampOptions(BLOptions o);

// Grabs the hardware and starts listening. On failure the engine is already stopped.
void BLStart(BLOptions opts, BLStartCompletion completion);

// Stops listening and restores the keyboard backlight (level and auto-brightness)
// and releases the trackpad. Synchronous; safe to call when not running.
void BLStop(void);

BOOL BLIsRunning(void);

// Applies new options while running. A change of audio source (useMic) is ignored
// here; stop and start again for that.
void BLUpdateOptions(BLOptions opts);

// Called if capture dies while running (e.g. the audio device went away).
// The engine has already stopped and restored the backlight when it fires.
void BLSetFailureHandler(void (^_Nullable handler)(NSString *reason));

BOOL BLBacklightActive(void);   // backlight is actually being driven
BOOL BLHapticsActive(void);     // trackpad actuator is actually open
BOOL BLRGBConnected(void);      // connected to OpenRGB (devices: ORGBDeviceCount/ORGBDeviceName in orgb.h)
BLMeter BLCurrentMeter(void);

NS_ASSUME_NONNULL_END
